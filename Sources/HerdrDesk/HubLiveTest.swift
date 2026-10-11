import HerdrKit
import Foundation
import AppKit

/// `--session <named> --test-hub <paneId> [--deny]`: the remote hub over a real WebSocket on 127.0.0.1, with this
/// app's store and input paths. A read-level device must be refused; with an approval open, `send` must be refused
/// (promptOpen), a stale prompt id must be refused, and the real id must answer. Without a prompt, `send` types a
/// short message. Refuses to run on the default session (checked at launch).
@MainActor
enum HubLiveTest {
    static func run(model: AppModel, paneId: String, allow: Bool) async {
        try? await Task.sleep(for: .seconds(3))
        await model.store.refresh()
        var ok = true
        func step(_ what: String, _ pass: Bool) { print("test-hub: \(pass ? "ok" : "FAIL") \(what)"); ok = ok && pass }

        let devices = MemoryDeviceStore()
        devices.add(token: "tok-input", device: HubDevice(id: "d-in", name: "Test phone", level: .input))
        devices.add(token: "tok-read", device: HubDevice(id: "d-ro", name: "Test tablet", level: .read))
        let server = HubServer(backend: AppHubBackend(model: model), devices: devices, tickInterval: .milliseconds(500))
        guard let port = try? await server.start(host: "127.0.0.1", port: 0) else { step("server start", false); finish(false); return }
        print("test-hub: listening on 127.0.0.1:\(port)")

        let ro = Client(port: port)
        try? await ro.send(#"{"v":1,"type":"hello","id":"h","token":"tok-read","client":"test-hub","clientVersion":"1"}"#)
        let roHello = await ro.untilReply()
        step("read device hello -> \(roHello.map(\.type))", roHello.last.map(isOK) == true)
        try? await ro.send(#"{"v":1,"type":"send","id":"s","pane":"\#(paneId)","text":"must not arrive"}"#)
        let roSend = await ro.untilReply().last
        step("read device send -> readOnly", errorCode(roSend) == .readOnly)
        ro.close()

        let c = Client(port: port)
        try? await c.send(#"{"v":1,"type":"hello","id":"h","token":"tok-input","client":"test-hub","clientVersion":"1"}"#)
        step("input device hello", await c.untilReply().last.map(isOK) == true)
        try? await c.send(#"{"v":1,"type":"watch","id":"w","pane":"\#(paneId)"}"#)
        let watch = await c.untilReply()
        step("watch -> \(watch.map(\.type))", watch.last.map(isOK) == true)
        let prompt = watch.compactMap { if case .prompt(let p) = $0 { p } else { nil } }.last
        print("test-hub: prompt = approval \(prompt?.approval.map { "\($0.id) \($0.tool) | \($0.command)" } ?? "none"), question \(prompt?.question?.id ?? "none")")

        if let a = prompt?.approval {
            try? await c.send(#"{"v":1,"type":"send","id":"s","pane":"\#(paneId)","text":"must not land in the picker"}"#)
            step("send while the approval is open -> promptOpen", errorCode(await c.untilReply().last) == .promptOpen)
            try? await c.send(#"{"v":1,"type":"approve","id":"a0","pane":"\#(paneId)","prompt":"toolu_stale","allow":\#(allow)}"#)
            step("approve with a stale id -> stale", errorCode(await c.untilReply().last) == .stale)
            let still = await model.store.client.checkPrompt(paneId: paneId)
            step("prompt still on screen after the refusals", still)
            try? await c.send(#"{"v":1,"type":"approve","id":"a1","pane":"\#(paneId)","prompt":"\#(a.id)","allow":\#(allow)}"#)
            step("\(allow ? "allow" : "deny") with the current id -> ok", await c.untilReply(8).last.map(isOK) == true)
            var cleared = false
            for _ in 0..<20 {
                guard let m = await c.next(1) else { continue }
                if case .prompt(let p) = m, p.approval == nil { cleared = true; break }
            }
            step("prompt push without the approval", cleared)
        } else if prompt?.question == nil {
            let word = "hub-ok-\(Int.random(in: 1000...9999))"
            try? await c.send(#"{"v":1,"type":"send","id":"s","pane":"\#(paneId)","text":"Reply with just: \#(word)"}"#)
            step("send -> ok", await c.untilReply(8).last.map(isOK) == true)
            // A pane without a transcript (CLAUDE_CODE_CHILD_SESSION) has no conversation to push; its screen still changes.
            var pushed: String?
            for _ in 0..<30 {
                guard let m = await c.next(1) else { continue }
                if case .conversation(let conv) = m, conv.mode == .append, !conv.items.isEmpty { pushed = "conversation"; break }
                if case .screen(let sc) = m, sc.text.components(separatedBy: word).count > 2 { pushed = "screen"; break }
            }
            step("\(pushed ?? "no") push after the send", pushed != nil)
        }
        c.close()
        server.stop()
        finish(ok)
    }

    private static func finish(_ ok: Bool) {
        print("test-hub: \(ok ? "PASS" : "FAIL")")
        NSApp.terminate(nil)
    }
    private static func isOK(_ m: HubMessage) -> Bool { if case .reply(let r) = m { r.ok } else { false } }
    private static func errorCode(_ m: HubMessage?) -> HubError.Code? { if case .reply(let r)? = m { r.error?.code } else { nil } }

    @MainActor final class Client {
        let task: URLSessionWebSocketTask
        init(port: UInt16) {
            task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/")!)
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
        func untilReply(_ seconds: Double = 3) async -> [HubMessage] {
            var out: [HubMessage] = []
            while let m = await next(seconds) { out.append(m); if case .reply = m { break } }
            return out
        }
        func close() { task.cancel(with: .goingAway, reason: nil) }
    }
}
