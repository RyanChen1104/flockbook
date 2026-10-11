import Foundation
import Network

/// Carries `HubSession` over WebSocket (`Network.framework`, no dependency). One session per connection; messages of a
/// connection are handled one at a time, and every `tickInterval` the session's pushes go out.
///
/// For now it binds only to the loopback address. Other addresses (Tailscale, LAN) come with TLS and the bind rules.
/// Off unless the app starts it.
@MainActor public final class HubServer {
    public enum StartError: Error, Equatable {
        /// Only 127.0.0.1 and ::1 for now.
        case notLoopback(String)
        case failed(String)
    }

    private let backend: HubBackend
    private let devices: HubDeviceStore
    private let tickInterval: Duration
    /// A connection that has not said hello by then is closed.
    public var helloTimeout: Duration = .seconds(10)
    /// The largest client message taken (bytes).
    public static let maxMessage = 1 << 20

    private var listener: NWListener?
    private var conns: [ObjectIdentifier: Conn] = [:]
    private let queue = DispatchQueue(label: "hub.server")

    public init(backend: HubBackend, devices: HubDeviceStore, tickInterval: Duration = .seconds(1)) {
        self.backend = backend; self.devices = devices; self.tickInterval = tickInterval
    }

    public var running: Bool { listener != nil }
    public var connectionCount: Int { conns.count }

    public static func isLoopback(_ host: String) -> Bool { host == "127.0.0.1" || host == "::1" || host == "localhost" }

    /// Starts listening and returns the port (`port` 0 = any free port).
    @discardableResult
    public func start(host: String = "127.0.0.1", port: UInt16) async throws -> UInt16 {
        guard Self.isLoopback(host) else { throw StartError.notLoopback(host) }
        stop()
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = Self.maxMessage
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host == "localhost" ? "127.0.0.1" : host), port: NWEndpoint.Port(rawValue: port) ?? .any)
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
        return bound
    }

    public func stop() {
        listener?.cancel()
        listener = nil
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
        let c = Conn(nw: nw, session: HubSession(backend: backend, devices: devices))
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
