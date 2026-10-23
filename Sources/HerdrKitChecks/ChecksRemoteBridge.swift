import Foundation
import Darwin
@testable import HerdrKit

// Remote herdr (Bridge): the local relay socket in front of `herdr remote-api-bridge`, and what the app says when the
// host cannot be reached. The host side runs with `RemoteHost(via: .local)` and small sh commands in place of herdr:
// no second machine, no herdr session.
@MainActor func checksRemoteBridge() async throws {
    // Classification: sample stderr from ssh and herdr → the problem and its next step.
    let table: [(Int32, String, RemoteProblem)] = [
        (255, "user@host: Permission denied (publickey).\r\n", .auth),
        (255, "Received disconnect from 192.0.2.1 port 22:2: Too many authentication failures\n", .auth),
        (255, "Host key verification failed.\n", .hostKey),
        (255, "@@@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n@@@@@@\nHost key verification failed.\n", .hostKey),
        (255, "No ED25519 host key is known for box and you have requested strict checking.\nHost key verification failed.\n", .hostKey),
        (255, "ssh: Could not resolve hostname nohost: nodename nor servname provided, or not known\n",
         .unreachable("ssh: Could not resolve hostname nohost: nodename nor servname provided, or not known")),
        (255, "ssh: connect to host box port 22: Connection refused\n", .unreachable("ssh: connect to host box port 22: Connection refused")),
        (255, "ssh: connect to host box port 22: Operation timed out\n", .unreachable("ssh: connect to host box port 22: Operation timed out")),
        (255, "ssh: connect to host box port 22: No route to host\n", .unreachable("ssh: connect to host box port 22: No route to host")),
        (127, RemoteHost.herdrMissingMarker + "\n", .herdrMissing),
        (1, "Error: failed to connect to remote Herdr API socket /home/u/.config/herdr/herdr.sock: Connection refused (os error 61)\n", .notRunning),
        (2, "error: unrecognized subcommand 'remote-api-bridge'\n\nUsage: herdr [OPTIONS] [COMMAND]\n", .bridgeUnsupported),
        (3, "something odd\n", .other("something odd")),
        (5, "", .other("exit status 5")),
        (-1, "", .unreachable("no answer within the time limit")),
    ]
    for (status, err, want) in table {
        let got = RemoteProblem.classify(status: status, stderr: err)
        check(got == want, "remote bridge: classify \(err.prefix(40).debugDescription) → \(want) (got \(got))")
    }

    // Texts: every remote case has a short line, a title and a next step; ssh steps name the destination.
    do {
        let host = try RemoteHost.ssh("user@host")
        let all: [RemoteProblem] = [.auth, .hostKey, .unreachable("No route to host"), .herdrMissing, .notRunning, .bridgeUnsupported, .other("odd")]
        for p in all {
            let c = ConnectionProblem.remote(p, host: host, session: "t")
            check(!c.short.isEmpty && !c.title.isEmpty && c.detail.contains("user@host"), "remote bridge: texts for \(p)")
        }
        check(ConnectionProblem.remote(.auth, host: host, session: nil).detail.contains("ssh-add"), "remote bridge: auth says ssh-add")
        check(ConnectionProblem.remote(.auth, host: host, session: nil).command == "ssh user@host", "remote bridge: auth command")
        let hk = ConnectionProblem.remote(.hostKey, host: host, session: nil)
        check(hk.command == "ssh user@host" && hk.detail.contains("never accepts"), "remote bridge: host key is the owner's call")
        check(ConnectionProblem.remote(.notRunning, host: host, session: "t").command == "herdr --remote user@host --session t",
              "remote bridge: not running → herdr --remote")
        check(ConnectionProblem.remote(.notRunning, host: host, session: nil).command == "herdr --remote user@host", "remote bridge: default session")
        check(ConnectionProblem.remote(.herdrMissing, host: host, session: nil).link == ConnectionProblem.herdrSite, "remote bridge: install link")
        check(ConnectionProblem.remote(.unreachable("x"), host: host, session: nil).command == nil, "remote bridge: unreachable has no command")
        // A remote session needs no herdr program on this Mac.
        check(ConnectionCheck.programWarning(session: .remote(host, name: nil), environment: ["PATH": "/nonexistent"], home: "/nonexistent", usual: []) == nil,
              "remote bridge: no local program warning for a remote session")
        check(ConnectionCheck.programWarning(session: .default(), environment: ["PATH": "/nonexistent"], home: "/nonexistent", usual: []) != nil,
              "remote bridge: local sessions still warn")
    }

    let local = RemoteHost(via: .local)
    var n = 0
    func path() -> String { n += 1; return RemoteHost.runtimeDir + "/chk-\(getpid())-\(n).sock" }
    func bridge(_ command: String) -> RemoteBridge { RemoteBridge(host: local, socketPath: path(), command: command) }
    func eventually(_ seconds: Double = 5, _ ok: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if ok() { return true }; try? await Task.sleep(for: .milliseconds(30)) }
        return ok()
    }

    // The default command is herdr's own bridge for the session.
    do {
        let b = RemoteBridge(session: .remote(local, name: "t"))
        check(b?.command == RemoteHost.herdrCommand(session: "t", ["remote-api-bridge"]), "remote bridge: default command")
        check(RemoteBridge(session: .default()) == nil, "remote bridge: none for a local session")
    }

    // Two connections at once: a long one (like events.subscribe) stays open while short ones come and go.
    let echo = "while IFS= read -r l; do printf '%s\\n' \"$l\"; done"
    do {
        let b = bridge(echo)
        try b.start()
        defer { b.stop() }
        let long = try BridgeConn(b.socketPath)
        try long.send("a1\n")
        check(long.line() == "a1", "remote bridge: long connection answers")
        for i in 0..<3 {
            let short = try BridgeConn(b.socketPath)
            try short.send("b\(i)\n")
            check(short.line() == "b\(i)", "remote bridge: short request \(i) answers while the long one is open")
            short.close()
        }
        try long.send("a2\n")
        check(long.line() == "a2", "remote bridge: long connection still answers")
        long.close()
        check(await eventually { b.openConnections == 0 }, "remote bridge: closed connections are gone (\(b.openConnections))")
    }

    // Socket file: mode 600; start twice is one listener; stop removes the file; start again works.
    do {
        let b = bridge(echo)
        try b.start(); try b.start()
        var st = stat()
        check(lstat(b.socketPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK && st.st_mode & 0o777 == 0o600,
              "remote bridge: socket mode 600 (\(String(st.st_mode & 0o777, radix: 8)))")
        b.stop(); b.stop()
        check(access(b.socketPath, F_OK) != 0 && !b.isRunning, "remote bridge: stop removes the socket")
        try b.start()
        let c = try BridgeConn(b.socketPath)
        try c.send("again\n")
        check(c.line() == "again", "remote bridge: restarts")
        c.close(); b.stop()
    }

    // A stale socket (nobody listens) is replaced; a file that is not a socket is left alone and start fails.
    do {
        let p = path()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in p.utf8.enumerated() { raw[i] = b }; raw[p.utf8.count] = 0 }
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(fd)
        check(ConnectionCheck.connectError(p) != 0, "remote bridge: the stale socket refuses")
        let b = RemoteBridge(host: local, socketPath: p, command: echo)
        try b.start()
        let c = try BridgeConn(p)
        try c.send("fresh\n")
        check(c.line() == "fresh", "remote bridge: stale socket replaced")
        c.close(); b.stop()

        let f = path()
        FileManager.default.createFile(atPath: f, contents: Data("keep".utf8))
        let bad = RemoteBridge(host: local, socketPath: f, command: echo)
        check((try? bad.start()) == nil && FileManager.default.contents(atPath: f) == Data("keep".utf8),
              "remote bridge: a plain file at the socket path is kept, start fails")
        unlink(f)
    }

    // Half-close: the client stops sending, the child sees EOF and still answers.
    do {
        let b = bridge("cat; echo end")
        try b.start()
        let c = try BridgeConn(b.socketPath)
        try c.send("x\n")
        c.halfClose()
        check(c.line() == "x" && c.line() == "end" && c.line() == nil, "remote bridge: half-close keeps the answer")
        c.close(); b.stop()
    }

    // The client goes away: the child is stopped (after the grace). The child goes away: the client sees EOF.
    do {
        let b = bridge("printf '%s\\n' $$; exec sleep 30")
        b.closeGrace = 0.2
        try b.start()
        let c = try BridgeConn(b.socketPath)
        let pid = c.line().flatMap { Int32($0) } ?? 0
        check(pid > 0 && kill(pid, 0) == 0, "remote bridge: child runs (\(pid))")
        c.close()
        check(await eventually { pid > 0 && kill(pid, 0) != 0 }, "remote bridge: child stopped when the client closes")
        check(await eventually { b.openConnections == 0 }, "remote bridge: connection released")
        check(b.lastFailure == nil, "remote bridge: a child the bridge stopped is not a failure")
        b.stop()

        let e = bridge("echo bye")
        try e.start()
        let d = try BridgeConn(e.socketPath)
        check(d.line() == "bye" && d.line() == nil, "remote bridge: child exit closes the client")
        d.close(); e.stop()
    }

    // stop() ends open connections and their children.
    do {
        let b = bridge("printf '%s\\n' $$; exec sleep 30")
        try b.start()
        let c = try BridgeConn(b.socketPath)
        let pid = c.line().flatMap { Int32($0) } ?? 0
        b.stop()
        check(await eventually { pid > 0 && kill(pid, 0) != 0 }, "remote bridge: stop ends the children")
        check(c.line() == nil, "remote bridge: stop closes the clients")
        c.close()
    }

    // A failed child: its stderr is kept and classified; a later good child clears it.
    let notRunning = "echo 'Error: failed to connect to remote Herdr API socket /x: Connection refused' >&2; exit 1"
    do {
        let b = bridge(notRunning)
        try b.start()
        let c = try BridgeConn(b.socketPath)
        check(c.line() == nil, "remote bridge: a failed child closes the client")
        c.close()
        check(await eventually { b.lastFailure?.problem == .notRunning }, "remote bridge: failure kept (\(String(describing: b.lastFailure)))")
        b.stop()
    }

    // diagnose for a remote session: the probe first, then the bridge's last failure, then the relay socket.
    do {
        let s = HerdrSession(name: "t", socketPath: path(), remote: local)
        func diag(_ probe: String, _ b: RemoteBridge?) async -> ConnectionProblem? {
            await ConnectionCheck.diagnose(remote: s, bridge: b, probe: probe)
        }
        let ok = "echo \(RemoteProblem.bridgeMarker)"
        check(await diag("echo 'Permission denied (publickey).' >&2; exit 255", nil) == .remote(.auth, host: local, session: "t"), "remote bridge: diagnose auth")
        check(await diag("echo \(RemoteHost.quote(RemoteHost.herdrMissingMarker)) >&2; exit 127", nil) == .remote(.herdrMissing, host: local, session: "t"),
              "remote bridge: diagnose herdr missing")
        check(await diag("echo something else", nil) == .remote(.bridgeUnsupported, host: local, session: "t"), "remote bridge: no marker → too old")
        let failing = RemoteBridge(host: local, socketPath: s.socketPath, command: notRunning)
        try failing.start()
        let c = try BridgeConn(s.socketPath)
        _ = c.line(); c.close()
        _ = await eventually { failing.lastFailure != nil }
        check(await diag(ok, failing) == .remote(.notRunning, host: local, session: "t"), "remote bridge: diagnose not running")
        failing.stop()
        let deaf = await diag(ok, nil)
        if case .remote(.other, _, _)? = deaf {} else { check(false, "remote bridge: relay not listening → other (\(String(describing: deaf)))") }
        let good = RemoteBridge(host: local, socketPath: s.socketPath, command: echo)
        try good.start()
        check(await diag(ok, good) == nil, "remote bridge: probe and relay fine → nil")
        good.stop()
    }
}

/// A blocking client of the relay socket for the checks (3 s read timeout).
private final class BridgeConn {
    private var fd: Int32
    private var buffer: [UInt8] = []

    init(_ path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in path.utf8.enumerated() { raw[i] = b }; raw[path.utf8.count] = 0 }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else { let e = errno; Darwin.close(fd); throw HerdrError.socket("connect \(e)") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func send(_ s: String) throws {
        let b = Array(s.utf8)
        guard Darwin.write(fd, b, b.count) == b.count else { throw HerdrError.socket("write \(errno)") }
    }

    /// The next line; nil at EOF, on a timeout or after `close`.
    func line() -> String? {
        while fd >= 0 {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let l = String(decoding: buffer[..<nl], as: UTF8.self)
                buffer.removeSubrange(...nl)
                return l
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[..<n])
        }
        return nil
    }

    func halfClose() { shutdown(fd, SHUT_WR) }
    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    deinit { close() }
}
