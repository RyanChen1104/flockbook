import Foundation
import Network

/// Carries `HubSession` over WebSocket (`Network.framework`, no dependency). One session per connection; messages of a
/// connection are handled one at a time, and every `tickInterval` the session's pushes go out.
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
    private let tickInterval: Duration
    /// A connection that has not said hello by then is closed.
    public var helloTimeout: Duration = .seconds(10)
    /// The largest client message taken (bytes).
    public static let maxMessage = 1 << 20

    private var listener: NWListener?
    private var conns: [ObjectIdentifier: Conn] = [:]
    private let queue = DispatchQueue(label: "hub.server")

    public init(backend: HubBackend, devices: HubDeviceStore, pairing: HubPairing? = nil, tickInterval: Duration = .seconds(1)) {
        self.backend = backend; self.devices = devices; self.pairing = pairing; self.tickInterval = tickInterval
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
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = Self.maxMessage
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
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
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

    public func stop() {
        listener?.cancel()
        listener = nil
        fingerprint = nil
        for c in conns.values { c.close() }
        conns = [:]
    }

    // MARK: - Connections

    private final class Conn {
        let nw: NWConnection
        let session: HubSession
        var chain: Task<Void, Never>?
        var ticker: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var closed = false
        init(nw: NWConnection, session: HubSession) { self.nw = nw; self.session = session }
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
        let c = Conn(nw: nw, session: HubSession(backend: backend, devices: devices, pairing: pairing))
        let key = ObjectIdentifier(c)
        conns[key] = c
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { @MainActor in self?.drop(key) }
            default: break
            }
        }
        nw.start(queue: queue)
        receive(key)
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
                if c.session.device != nil { self.serially(key) { await $0.session.tick() } }
            }
        }
    }

    private func drop(_ key: ObjectIdentifier) {
        conns.removeValue(forKey: key)?.close()
    }

    private func receive(_ key: ObjectIdentifier) {
        guard let c = conns[key] else { return }
        c.nw.receiveMessage { [weak self] data, context, _, error in
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            let opcode = meta?.opcode
            Task { @MainActor in
                guard let self else { return }
                guard error == nil, opcode != .close, let data else { self.drop(key); return }
                if opcode == .text || opcode == .binary {
                    self.serially(key) { await $0.session.receive(data) }
                }
                self.receive(key)
            }
        }
    }

    /// Runs one session step after the previous one, sends its messages, and closes when the session closed.
    private func serially(_ key: ObjectIdentifier, _ step: @escaping @MainActor (Conn) async -> [HubMessage]) {
        guard let c = conns[key] else { return }
        let prev = c.chain
        c.chain = Task { @MainActor [weak self] in
            await prev?.value
            guard let self, let c = self.conns[key], !c.closed else { return }
            let out = await step(c)
            for m in out { await self.send(m, on: c) }
            if c.session.closed { self.drop(key) }
        }
    }

    private func send(_ m: HubMessage, on c: Conn) async {
        guard let data = try? Hub.encode(m) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "hub", metadata: [meta])
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            c.nw.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in k.resume() })
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
