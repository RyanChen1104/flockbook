import Foundation
@testable import HerdrKit

/// A WebSocket test client (Foundation only).
@MainActor final class HubTestClient {
    let task: URLSessionWebSocketTask
    convenience init(port: UInt16) { self.init(task: URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)) }
    init(task: URLSessionWebSocketTask) {
        self.task = task
        task.resume()
        read()
    }
    func send(_ json: String) async throws { try await task.send(.string(json)) }
    /// `receive()` ignores task cancellation, so one reader loop fills an inbox and `next` polls it.
    private var inbox: [HubMessage] = []
    private var ended = false
    private func read() {
        Task { @MainActor [weak self, task] in
            while true {
                guard case .string(let s)? = try? await task.receive() else { self?.ended = true; return }
                if let m = try? Hub.decodeHub(Data(s.utf8)) { self?.inbox.append(m) }
            }
        }
    }
    /// The next message, or nil after `seconds` or when the connection is closed.
    func next(_ seconds: Double = 3) async -> HubMessage? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while inbox.isEmpty, !ended, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return inbox.isEmpty ? nil : inbox.removeFirst()
    }
    /// Messages until a reply arrives (inclusive).
    func untilReply(_ seconds: Double = 3) async -> [HubMessage] {
        var out: [HubMessage] = []
        while let m = await next(seconds) { out.append(m); if case .reply = m { break } }
        return out
    }
    func close() { task.cancel(with: .goingAway, reason: nil) }
}

// HubServer: the WebSocket transport, on 127.0.0.1 (bind rules and TLS: ChecksHubTLS).
@MainActor func checksHubServer() async throws {
    let a = Agent(name: "claude", kind: "claude", status: .working, sessionId: "s1", title: "t")
    let ws = [Workspace(id: "w1", label: "web", tabs: [Tab(id: "w1:t1", label: "build", number: 1,
                        panes: [Pane(id: "w1:p1", terminalId: "term_1", cwd: "/work", agent: a)], status: .working)])]
    let b = FakeHubBackend(workspaces: ws)
    b.items["s1"] = [ConversationItem(id: "i0", kind: .userText("Fix the build"))]
    b.screens["w1:p1"] = "working…"
    let devices = MemoryDeviceStore()
    devices.add(token: "tok", device: HubDevice(id: "d1", name: "Phone", level: .input))

    let server = HubServer(backend: b, devices: devices, tickInterval: .milliseconds(200))
    for host in ["0.0.0.0", "::", "192.168.1.5", "100.64.0.1"] {
        var refused = false
        do { _ = try await server.start(host: host, port: 0) } catch is HubServer.StartError { refused = true }
        check(refused && !server.running, "hub server: refuses to bind \(host) without TLS")
    }
    let port = try await server.start(host: "127.0.0.1", port: 0)
    check(port > 0 && server.running, "hub server: listening on 127.0.0.1:\(port)")

    // A paired device: hello, watch, then a live push from the tick.
    let c = HubTestClient(port: port)
    try await c.send(#"{"v":1,"type":"hello","id":"h","token":"tok","client":"check","clientVersion":"1"}"#)
    let hello = await c.untilReply()
    check(hello.map(\.type) == ["welcome", "snapshot", "reply"], "hub server: hello over WebSocket -> welcome, snapshot, reply (\(hello.map(\.type)))")
    try await c.send(#"{"v":1,"type":"watch","id":"w","pane":"w1:p1"}"#)
    let watch = await c.untilReply()
    check(watch.map(\.type) == ["conversation", "screen", "prompt", "reply"], "hub server: watch over WebSocket (\(watch.map(\.type)))")
    b.items["s1"]?.append(ConversationItem(id: "i1", kind: .assistantText("Done.")))
    let pushed = await c.next(2)
    if case .conversation(let conv)? = pushed { check(conv.mode == .append && conv.items.map(\.id) == ["i1"], "hub server: tick pushes the new item") }
    else { check(false, "hub server: tick pushes the new item (\(pushed?.type ?? "nothing"))") }
    check(server.connectionCount == 1, "hub server: one connection")

    // An unknown token: unauthorized, then the hub closes.
    let bad = HubTestClient(port: port)
    try await bad.send(#"{"v":1,"type":"hello","id":"h","token":"nope","client":"check","clientVersion":"1"}"#)
    let r = await bad.next()
    if case .reply(let rep)? = r { check(rep.error?.code == .unauthorized, "hub server: unknown token -> unauthorized") } else { check(false, "hub server: unknown token -> a reply") }
    check(await bad.next(2) == nil, "hub server: closes after unauthorized")

    // Pairing over the socket, then hello with the new token on a new connection.
    let pairing = HubPairing(devices: devices)
    server.pairing = pairing
    let offer = pairing.offer()
    let pc = HubTestClient(port: port)
    try await pc.send(#"{"v":1,"type":"pair","id":"p","secret":"\#(offer.code)","name":"Laptop"}"#)
    let paired = await pc.untilReply()
    if case .paired(let pd)? = paired.first {
        pc.close()
        let nc = HubTestClient(port: port)
        try await nc.send(#"{"v":1,"type":"hello","id":"h","token":"\#(pd.token)","client":"check","clientVersion":"1"}"#)
        let w = await nc.untilReply()
        check(w.map(\.type) == ["welcome", "snapshot", "reply"] && devices.device(token: pd.token)?.level == .read, "hub server: pair with the 6 words, then hello with the token")
        nc.close()
    } else { check(false, "hub server: pair -> paired (\(paired.map(\.type)))") }
    server.pairing = nil
    try? await Task.sleep(for: .milliseconds(200))

    // No hello in time: closed.
    server.helloTimeout = .milliseconds(300)
    let silent = HubTestClient(port: port)
    try? await Task.sleep(for: .milliseconds(150))
    let before = server.connectionCount
    try? await Task.sleep(for: .milliseconds(700))
    check(before == 2 && server.connectionCount == 1, "hub server: a client without hello is closed (\(before) -> \(server.connectionCount))")

    c.close(); bad.close(); silent.close()
    server.stop()
    check(!server.running && server.connectionCount == 0, "hub server: stop closes everything")
    let late = HubTestClient(port: port)
    try? await late.send(#"{"v":1,"type":"ping","id":"p"}"#)
    check(await late.next(1) == nil, "hub server: nothing answers after stop")
    late.close()
}
