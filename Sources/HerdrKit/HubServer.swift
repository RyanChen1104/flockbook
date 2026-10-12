import Foundation
import Network

/// Carries `HubSession` over WebSocket, and serves the PWA's files from the same origin (`HubHTTP.swift`; TCP and TLS
/// from Network.framework, no dependency). `GET /ws` with an upgrade is the socket: one session per connection,
/// messages handled one at a time, and every `tickInterval` the session's pushes go out. Other GETs get a file.
///
/// It listens on one address the owner picks (`HubBind`): loopback, or a Tailscale/LAN address with TLS. Never all
/// addresses. Off unless the app starts it.
@MainActor public final class HubServer {
    public enum StartError: Error, Equatable {
        /// All addresses (0.0.0.0, ::): never.
        case wildcard(String)
        /// Not an address of this Mac now.
        case notLocal(String)
        /// Neither loopback, Tailscale nor a private LAN address.
        case publicAddress(String)
        /// Every address but loopback needs TLS.
        case needsTLS(String)
        case failed(String)
    }

    private let backend: HubBackend
    private let devices: HubDeviceStore
    /// Set while the hub may pair devices (`pair` is refused without it).
    public var pairing: HubPairing?
    /// Behind Tailscale Serve: the only page origin whose socket is taken (`https://<machine>.<tailnet>.ts.net:<port>`).
    /// Serve passes every request on from 127.0.0.1 and may rewrite Host, so then the Origin alone decides, and a
    /// request without one is refused. Nil: the Origin, when sent, must name the Host.
    public var allowedOrigin: String?
    private let tickInterval: Duration
    /// A connection that has not said hello by then is closed.
    public var helloTimeout: Duration = .seconds(10)
    /// The largest client message taken (bytes).
    public static let maxMessage = 1 << 20
    /// Connections without a paired device (a page load, pairing, before hello) held at once; more are refused.
    public static let maxPending = 16
    /// Connections held at once in all.
    public static let maxConnections = 64

    private var listener: NWListener?
    /// Keyed by a number never used twice: a late callback of a closed connection finds nothing, so it can never
    /// touch a newer connection (an object address, by contrast, is reused once the old connection is freed).
    private var conns: [Int: Conn] = [:]
    private var lastID = 0
    private let queue = DispatchQueue(label: "hub.server")

    private let assets: HubWeb.Assets

    public init(backend: HubBackend, devices: HubDeviceStore, pairing: HubPairing? = nil, assets: HubWeb.Assets = HubWeb.bundled,
                tickInterval: Duration = .seconds(1)) {
        self.backend = backend; self.devices = devices; self.pairing = pairing; self.assets = assets; self.tickInterval = tickInterval
    }

    public var running: Bool { listener != nil }
    public var connectionCount: Int { conns.count }
    /// The certificate fingerprint while listening with TLS.
    public private(set) var fingerprint: String?

    /// Starts listening on one address of this Mac and returns the port (`port` 0 = any free port). The address
    /// follows `HubBind.check` (`local` = this Mac's addresses; tests pass their own).
    @discardableResult
    public func start(host: String = "127.0.0.1", port: UInt16, tls: HubIdentity? = nil, local: [HubAddress]? = nil) async throws -> UInt16 {
        stop()
        if let e = HubBind.check(host: host, tls: tls != nil, local: local ?? HubBind.local()) { throw e }
        let params: NWParameters
        if let tls, let sid = sec_identity_create(tls.identity) {
            let t = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(t.securityProtocolOptions, sid)
            sec_protocol_options_set_min_tls_protocol_version(t.securityProtocolOptions, .TLSv12)
            params = NWParameters(tls: t, tcp: NWProtocolTCP.Options())
        } else if tls != nil {
            throw StartError.failed("TLS identity unusable")
        } else {
            params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        }
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let l: NWListener
        do { l = try NWListener(using: params) } catch { throw StartError.failed("\(error)") }
        l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.accept(c) } }
        let bound: UInt16 = try await withCheckedThrowingContinuation { (k: CheckedContinuation<UInt16, Error>) in
            let once = Once()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { k.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e): once.run { k.resume(throwing: StartError.failed("\(e)")) }
                case .cancelled: once.run { k.resume(throwing: StartError.failed("cancelled")) }
                default: break
                }
            }
            l.start(queue: queue)
        }
        listener = l
        fingerprint = tls?.fingerprint
        return bound
    }

    /// Closes the connections of devices that were removed (call after a revoke), at once rather than on their next
    /// message or push.
    public func dropRevoked() {
        for c in conns.values where c.session.revoked { finish(c, WebSocketFrames.close(1008)) }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        fingerprint = nil
        for c in conns.values { c.close() }
        conns = [:]
    }

    // MARK: - Connections

    private final class Conn {
        enum Mode { case head(Data), socket(WebSocketFrames), done }
        let id: Int
        let nw: NWConnection
        let session: HubSession
        var mode: Mode = .head(Data())
        var chain: Task<Void, Never>?
        var ticker: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var closed = false
        init(id: Int, nw: NWConnection, session: HubSession) { self.id = id; self.nw = nw; self.session = session }
        var isSocket: Bool { if case .socket = mode { true } else { false } }
        func close() {
            guard !closed else { return }
            closed = true
            ticker?.cancel()
            deadline?.cancel()
            nw.cancel()
        }
    }

    private func accept(_ nw: NWConnection) {
        guard listener != nil else { nw.cancel(); return }
        // Unpaired connections cost nothing to open: hold only a few at once.
        let pending = conns.values.filter { $0.session.device == nil }.count
        guard pending < Self.maxPending, conns.count < Self.maxConnections else { nw.cancel(); return }
        lastID += 1
        let c = Conn(id: lastID, nw: nw, session: HubSession(backend: backend, devices: devices, pairing: pairing, source: Self.source(nw)))
        let key = c.id
        conns[key] = c
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { @MainActor in self?.drop(key) }
            default: break
            }
        }
        nw.start(queue: queue)
        receive(key)
        // A socket that has not said hello in time, or a request head that never ends, is closed.
        let timeout = helloTimeout, interval = tickInterval
        c.deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, let c = self.conns[key], c.session.device == nil else { return }
            self.drop(key)
        }
        c.ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, let c = self.conns[key], !c.closed else { return }
                if c.isSocket, c.session.device != nil { self.serially(key) { await $0.session.tick() } }
            }
        }
    }

    /// The peer's address without the port (wrong pairing tries are counted per address).
    private static func source(_ nw: NWConnection) -> String {
        if case .hostPort(let host, _) = nw.endpoint { return "\(host)" }
        return "\(nw.endpoint)"
    }

    private func drop(_ key: Int) {
        conns.removeValue(forKey: key)?.close()
    }

    private func receive(_ key: Int) {
        guard let c = conns[key] else { return }
        c.nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, end, error in
            Task { @MainActor in
                guard let self, self.conns[key] != nil else { return }
                if let data, !data.isEmpty { self.take(data, key) }
                if end || error != nil { self.drop(key) } else { self.receive(key) }
            }
        }
    }

    private func take(_ data: Data, _ key: Int) {
        guard let c = conns[key] else { return }
        switch c.mode {
        case .done:
            return
        case .head(var buf):
            buf.append(data)
            guard let end = HTTPHead.end(in: buf) else {
                if buf.count > HTTPHead.maxHead { finish(c, HTTPHead.response("431 Request Header Fields Too Large")) } else { c.mode = .head(buf) }
                return
            }
            guard end - buf.startIndex <= HTTPHead.maxHead, let head = HTTPHead.parse(buf[buf.startIndex..<(end - 4)]) else {
                finish(c, HTTPHead.response(end - buf.startIndex > HTTPHead.maxHead ? "431 Request Header Fields Too Large" : "400 Bad Request")); return
            }
            request(head, rest: Data(buf[end...]), c, key)
        case .socket(var frames):
            let events = frames.feed(data)
            c.mode = .socket(frames)
            handle(events, key)
        }
    }

    private func request(_ head: HTTPHead, rest: Data, _ c: Conn, _ key: Int) {
        guard head.method == "GET" || head.method == "HEAD" else { finish(c, HTTPHead.response("405 Method Not Allowed", extra: [("Allow", "GET")])); return }
        if head.header("upgrade")?.lowercased() == "websocket" {
            guard head.path == "/ws" else { finish(c, HTTPHead.response("404 Not Found")); return }
            guard let wsKey = head.header("sec-websocket-key"), head.header("sec-websocket-version") == "13",
                  head.header("connection")?.lowercased().contains("upgrade") == true else { finish(c, HTTPHead.response("400 Bad Request")); return }
            // A page from another origin must not use a paired browser's socket (the token is still needed, too).
            if let allowedOrigin {
                guard head.header("origin")?.lowercased() == allowedOrigin.lowercased() else { finish(c, HTTPHead.response("403 Forbidden")); return }
            } else if let origin = head.header("origin") {
                let authority = origin.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
                guard authority == head.header("host") else { finish(c, HTTPHead.response("403 Forbidden")); return }
            }
            let accept = WebSocketFrames.accept(key: wsKey)
            c.mode = .socket(WebSocketFrames(maxMessage: Self.maxMessage))
            write(c, Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
            if !rest.isEmpty { take(rest, key) }
            return
        }
        guard let f = assets.file(head.path) else { finish(c, HTTPHead.response("404 Not Found", type: "text/plain; charset=utf-8", body: Data("Not found".utf8))); return }
        let full = HTTPHead.response("200 OK", type: f.type, body: f.body, extra: HubWeb.headers)
        finish(c, head.method == "HEAD" ? full.prefix(full.count - f.body.count) : full)
    }

    private func handle(_ events: [WebSocketFrames.Event], _ key: Int) {
        guard let c = conns[key] else { return }
        for e in events {
            switch e {
            case .message(let d): serially(key) { await $0.session.receive(d) }
            case .ping(let d): write(c, WebSocketFrames.encode(opcode: 10, d))
            case .close: finish(c, WebSocketFrames.close(1000))
            case .fail(let code): finish(c, WebSocketFrames.close(code))
            }
        }
    }

    /// Writes the last bytes of a connection, then closes it.
    private func finish(_ c: Conn, _ data: Data) {
        c.mode = .done
        let key = c.id
        c.nw.send(content: data, completion: .contentProcessed { [weak self] _ in Task { @MainActor in self?.drop(key) } })
    }

    private func write(_ c: Conn, _ data: Data) {
        c.nw.send(content: data, completion: .idempotent)
    }

    /// Runs one session step after the previous one, sends its messages, and closes when the session closed.
    private func serially(_ key: Int, _ step: @escaping @MainActor (Conn) async -> [HubMessage]) {
        guard let c = conns[key] else { return }
        let prev = c.chain
        c.chain = Task { @MainActor [weak self] in
            await prev?.value
            guard let self, let c = self.conns[key], !c.closed, c.isSocket else { return }
            let out = await step(c)
            for m in out { await self.send(m, on: c) }
            if c.session.closed { self.finish(c, WebSocketFrames.close(1008)) }
        }
    }

    private func send(_ m: HubMessage, on c: Conn) async {
        guard let data = try? Hub.encode(m) else { return }
        let frame = WebSocketFrames.encode(opcode: 1, data)
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            c.nw.send(content: frame, completion: .contentProcessed { _ in k.resume() })
        }
    }
}

/// Runs a closure once, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ f: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        f()
    }
}
