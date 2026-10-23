import Foundation
import Darwin

// The herdr API of a remote host as a local Unix socket, so `HerdrClient` talks to it like to herdr on this Mac.
//
// Every connection to the relay socket gets its own `herdr --session S remote-api-bridge` on the host (through
// `RemoteHost.process`, so ssh with a shared ControlMaster connection), and bytes are copied both ways until one side
// ends. Connections run at the same time: `HerdrClient` keeps `events.subscribe` open while it sends short requests
// (herdr's own local relay serves one connection at a time). A dead ssh only ends its connection; the next connection
// starts a new one, so the store's reconnect loop also reconnects the host.

/// Why the host side failed, from ssh's or herdr's exit status and stderr.
public enum RemoteProblem: Sendable, Hashable {
    /// ssh could not log in with a key (BatchMode: no password prompts).
    case auth
    /// The host key is unknown or changed; only the owner may accept it.
    case hostKey
    /// No connection to the host: name, network, port or time-out. The value is ssh's line.
    case unreachable(String)
    /// No herdr program on the host (`RemoteHost.herdrMissingMarker`).
    case herdrMissing
    /// herdr is installed, but its server for the session is not running on the host.
    case notRunning
    /// herdr on the host has no `remote-api-bridge` (too old).
    case bridgeUnsupported
    /// Anything else: the last line of stderr, or the exit status.
    case other(String)

    /// What `herdr remote-api-bridge --check` prints.
    public static let bridgeMarker = "herdr-api-bridge-v1"

    /// The problem for a host command that exited with `status` (-1: killed after its time limit) and `stderr`.
    public static func classify(status: Int32, stderr: String) -> RemoteProblem {
        let low = stderr.lowercased()
        func has(_ any: String...) -> Bool { any.contains { low.contains($0) } }
        // herdr's own line first: it may end in an ssh-like reason ("Connection refused").
        if has("failed to connect to remote herdr api socket") { return .notRunning }
        if status == 127, stderr.contains(RemoteHost.herdrMissingMarker) { return .herdrMissing }
        if has("host key verification failed", "remote host identification has changed", "host key is known", "host key for") {
            return .hostKey
        }
        if has("permission denied (", "too many authentication failures", "authentication failed", "no supported authentication methods") {
            return .auth
        }
        if has("could not resolve hostname", "connection refused", "timed out", "no route to host", "network is unreachable",
               "connection closed by", "connection reset by", "host is down") {
            return .unreachable(lastLine(stderr) ?? "no connection")
        }
        if status == -1 { return .unreachable("no answer within the time limit") }
        if has("remote-api-bridge"), has("unrecognized subcommand", "unknown subcommand", "invalid subcommand", "unexpected argument") {
            return .bridgeUnsupported
        }
        return .other(lastLine(stderr) ?? "exit status \(status)")
    }

    /// The last line with text, at most 300 characters.
    static func lastLine(_ s: String) -> String? {
        let l = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        return l.map { String($0.prefix(300)) }
    }
}

/// The local relay socket for one remote herdr session. `start()` listens, `stop()` closes it and every connection.
public final class RemoteBridge: @unchecked Sendable {
    public let host: RemoteHost
    /// The relay socket (in `RemoteHost.runtimeDir`, mode 600).
    public let socketPath: String
    /// The host command each connection runs; its stdin and stdout carry herdr's API.
    public let command: String

    /// A host command that ended badly, for `ConnectionCheck.diagnose(remote:)`.
    public struct Failure: Sendable, Hashable {
        public let status: Int32
        public let stderr: String
        public let at: Date
        public var problem: RemoteProblem { .classify(status: status, stderr: stderr) }
    }

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    /// Bumped by every start and stop; an accept loop of an older one ends.
    private var generation = 0
    /// The socket file this bridge made (device, inode): `stop` removes only that one.
    private var made: (dev_t, ino_t)?
    private var links: [ObjectIdentifier: Link] = [:]
    private var _lastFailure: Failure?
    private var _closeGrace: TimeInterval = 5

    public init(host: RemoteHost, socketPath: String, command: String) {
        self.host = host; self.socketPath = socketPath; self.command = command
    }

    /// The relay for `session`: herdr's own bridge on its host. Nil: a session on this Mac.
    public convenience init?(session: HerdrSession) {
        guard let host = session.remote else { return nil }
        self.init(host: host, socketPath: session.socketPath, command: RemoteHost.herdrCommand(session: session.name, ["remote-api-bridge"]))
    }

    public var isRunning: Bool { lock.withLock { listenFD >= 0 } }
    /// Connections open now.
    public var openConnections: Int { lock.withLock { links.count } }
    /// The last host command that failed; nil after one ends well.
    public var lastFailure: Failure? { lock.withLock { _lastFailure } }
    /// After the client stops sending, how long its host command may still answer before the bridge stops it.
    public var closeGrace: TimeInterval { get { lock.withLock { _closeGrace } } set { lock.withLock { _closeGrace = newValue } } }

    /// Listens on `socketPath`. A stale socket there is replaced; any other file there is kept and start throws.
    /// Does nothing while running.
    public func start() throws {
        try lock.withLock {
            guard listenFD < 0 else { return }
            signal(SIGPIPE, SIG_IGN)
            Self.removeStaleSockets(in: try RemoteHost.ensureRuntimeDir())
            let fd = try Self.listen(at: socketPath)
            var st = stat()
            made = lstat(socketPath, &st) == 0 ? (st.st_dev, st.st_ino) : nil
            listenFD = fd
            generation += 1
            let gen = generation
            Thread.detachNewThread { [self] in acceptLoop(fd, gen) }
        }
    }

    /// Stops listening, removes the socket file (if it is still ours) and ends every connection and its host command.
    public func stop() {
        let open: [Link] = lock.withLock {
            generation += 1
            if listenFD >= 0 {
                listenFD = -1   // the accept loop sees the new generation and closes it (within 250 ms)
                var st = stat()
                if let made, lstat(socketPath, &st) == 0, st.st_dev == made.0, st.st_ino == made.1 { unlink(socketPath) }
                made = nil
            }
            return Array(links.values)
        }
        for l in open { l.end() }
    }

    // MARK: - Listening

    /// Removes relay sockets (`api-<key>-<pid>.sock`, `HerdrSession.remote`) whose app run has ended. Only sockets of
    /// this user whose pid is gone; other files and ssh's control sockets stay.
    static func removeStaleSockets(in dir: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for n in names where n.hasPrefix("api-") && n.hasSuffix(".sock") {
            guard let pid = Int32(n.dropLast(5).split(separator: "-").last ?? ""), pid > 0, pid != getpid(),
                  kill(pid, 0) != 0, errno == ESRCH else { continue }
            let p = dir + "/" + n
            var st = stat()
            if lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() { unlink(p) }
        }
    }

    /// Binds and listens on `path` (mode 600, close-on-exec, non-blocking).
    static func listen(at path: String) throws -> Int32 {
        var st = stat()
        if lstat(path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFSOCK else { throw HerdrError.socket("\(path) exists and is not a socket") }
            unlink(path)   // this run's earlier relay for the same session (the name holds the pid): replacing it is fine
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrError.socket("socket() failed: \(errno)") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(fd); throw HerdrError.socket("path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { let e = errno; Darwin.close(fd); throw HerdrError.socket("bind \(path): \(String(cString: strerror(e)))") }
        guard chmod(path, 0o600) == 0, Darwin.listen(fd, 32) == 0 else {
            let e = errno; Darwin.close(fd); unlink(path)
            throw HerdrError.socket("listen \(path): \(String(cString: strerror(e)))")
        }
        return fd
    }

    /// Accepts until `stop` (or a newer `start`) bumps the generation, then closes `fd`. Only this loop closes `fd`,
    /// so it never calls accept on a number that already belongs to another file.
    private func acceptLoop(_ fd: Int32, _ gen: Int) {
        defer { Darwin.close(fd) }
        while lock.withLock({ generation == gen }) {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 250) > 0 else { continue }
            let c = accept(fd, nil, nil)
            if c < 0 {
                if errno == EINTR || errno == ECONNABORTED || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                return
            }
            guard lock.withLock({ generation == gen }) else { Darwin.close(c); return }
            _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)   // the copy loops block (after poll)
            _ = fcntl(c, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            open(c)
        }
    }

    /// Starts the host command for client `c` and relays.
    private func open(_ c: Int32) {
        let p: Process
        let toChild = Pipe(), fromChild = Pipe(), errors = Pipe()
        do {
            p = try host.process(command)
            p.standardInput = toChild; p.standardOutput = fromChild; p.standardError = errors
        } catch {
            failed(Failure(status: -2, stderr: "cannot start: \(error)", at: Date())); Darwin.close(c); return
        }
        let link = Link(client: c, process: p, toChild: toChild.fileHandleForWriting, fromChild: fromChild.fileHandleForReading,
                        errors: errors.fileHandleForReading, grace: closeGrace)
        let id = ObjectIdentifier(link)
        lock.withLock { links[id] = link }
        link.run(answered: { [weak self] in
            // The host command spoke: whatever failed before is over.
            self?.lock.withLock { self?._lastFailure = nil }
        }, done: { [weak self] failure in
            guard let self else { return }
            self.lock.withLock {
                self.links[id] = nil
                if let failure { self._lastFailure = failure }
            }
        }, startFailed: { [weak self] error in
            guard let self else { return }
            self.lock.withLock { self.links[id] = nil }
            self.failed(Failure(status: -2, stderr: "cannot start: \(error.localizedDescription)", at: Date()))
        })
    }

    private func failed(_ f: Failure) { lock.withLock { _lastFailure = f } }
}

/// One client connection and its host command.
private final class Link: @unchecked Sendable {
    let client: Int32
    let process: Process
    let toChild: FileHandle
    let fromChild: FileHandle
    let errors: FileHandle
    let grace: TimeInterval

    private struct State {
        var exitedAt: Date?
        var stopped = false
        var stdinClosed = false
        /// `client` is closed: its number may belong to another file now.
        var clientClosed = false
        var answered = false
        var stderr = Data()
    }
    private let state = Locked(State())

    init(client: Int32, process: Process, toChild: FileHandle, fromChild: FileHandle, errors: FileHandle, grace: TimeInterval) {
        self.client = client; self.process = process; self.toChild = toChild; self.fromChild = fromChild; self.errors = errors
        self.grace = grace
    }

    /// Starts the process and both copy threads. `answered`: the first bytes reached the client. `done`: the failure
    /// (nil: it ended well, or the bridge stopped it).
    func run(answered: @escaping @Sendable () -> Void, done: @escaping @Sendable (RemoteBridge.Failure?) -> Void,
             startFailed: @escaping @Sendable (Error) -> Void) {
        self.answered = answered
        let group = DispatchGroup()
        errors.readabilityHandler = { [state] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            state.update { s in s.stderr.append(d); if s.stderr.count > 8192 { s.stderr.removeFirst(s.stderr.count - 8192) } }
        }
        group.enter()
        process.terminationHandler = { [state] _ in state.update { $0.exitedAt = Date() }; group.leave() }
        do { try process.run() } catch {
            errors.readabilityHandler = nil
            Darwin.close(client)
            try? toChild.close(); try? fromChild.close(); try? errors.close()
            startFailed(error)
            return
        }
        group.enter(); Thread.detachNewThread { [self] in up(); group.leave() }
        group.enter(); Thread.detachNewThread { [self] in down(); group.leave() }
        group.notify(queue: .global()) { [self] in
            // A moment for the last stderr bytes to arrive.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
                errors.readabilityHandler = nil
                state.update { s in s.clientClosed = true; Darwin.shutdown(client, SHUT_RDWR); Darwin.close(client) }
                closeStdin()
                try? fromChild.close(); try? errors.close()
                let s = state.get()
                // Killed by a signal: 128 + signal, as sh reports it (-1 means "timed out" to `classify`).
                let status = process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus
                if s.stopped || status == 0 { done(nil); return }
                done(RemoteBridge.Failure(status: status, stderr: String(decoding: s.stderr, as: UTF8.self), at: Date()))
            }
        }
    }

    private var answered: (@Sendable () -> Void)?
    private var exited: Bool { state.get().exitedAt != nil }

    /// Client → host command, until the client stops sending or the command exits.
    private func up() {
        let inFD = toChild.fileDescriptor
        var buf = [UInt8](repeating: 0, count: 65536)
        while !exited {
            guard Self.readable(client) else { continue }
            let n = Darwin.read(client, &buf, buf.count)
            if n > 0 {
                if !Self.writeAll(inFD, buf, n) { break }   // the command closed its stdin or ended
                continue
            }
            if n < 0, errno == EINTR || errno == EAGAIN { continue }
            // EOF (or a broken client): the command gets EOF too and may still answer for `grace` seconds.
            closeStdin()
            let g = grace
            DispatchQueue.global().asyncAfter(deadline: .now() + g) { [self] in if !exited { end() } }
            return
        }
        closeStdin()
    }

    /// Host command → client, until the command closes its stdout (or exited a second ago and a child of it keeps
    /// stdout open). Then the client gets EOF.
    private func down() {
        let outFD = fromChild.fileDescriptor
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            guard Self.readable(outFD) else {
                if let at = state.get().exitedAt, Date().timeIntervalSince(at) > 1 { break }
                continue
            }
            let n = Darwin.read(outFD, &buf, buf.count)
            if n > 0 {
                if !Self.writeAll(client, buf, n) { end(); break }   // the client is gone
                if state.update({ s -> Bool in defer { s.answered = true }; return !s.answered }) { answered?() }
                continue
            }
            if n < 0, errno == EINTR || errno == EAGAIN { continue }
            break
        }
        Darwin.shutdown(client, SHUT_WR)
    }

    private func closeStdin() {
        let close = state.update { s -> Bool in defer { s.stdinClosed = true }; return !s.stdinClosed }
        if close { try? toChild.close() }
    }

    /// Stops the host command (TERM, then KILL after 2 s) and wakes both copy threads. Not a failure.
    func end() {
        state.update { s in
            s.stopped = true
            if !s.clientClosed { Darwin.shutdown(client, SHUT_RDWR) }
        }
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in if !exited { kill(pid, SIGKILL) } }
    }

    /// Waits up to 250 ms for `fd` to have data or EOF.
    private static func readable(_ fd: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, 250) > 0
    }

    private static func writeAll(_ fd: Int32, _ buf: [UInt8], _ n: Int) -> Bool {
        buf.withUnsafeBytes { raw in
            var off = 0
            while off < n {
                let w = Darwin.write(fd, raw.baseAddress! + off, n - off)
                if w > 0 { off += w; continue }
                if w < 0, errno == EINTR || errno == EAGAIN { continue }
                return false
            }
            return true
        }
    }
}
