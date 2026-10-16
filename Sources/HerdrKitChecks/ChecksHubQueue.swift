import Foundation
@testable import HerdrKit

// The hub and the agents' own queues: a `queued` push for a watched pane, and `pullQueued`, which takes the queue back
// into the device's composer through the backend (QueuePull) only after the hub's own checks.
@MainActor func checksHubQueue() async throws {
    let rule = String(repeating: "─", count: 60)
    func screen(_ queued: [String], input: String = "❯ Press up to edit queued messages") -> String {
        (["⏺ Working on it"] + queued.map { "❯ " + $0 } + ["  ctrl+enter to send now", "· Baking… (12s)", rule, input, rule]).joined(separator: "\n")
    }
    func ws(_ status: AgentStatus, kind: String = "claude") -> [Workspace] {
        let a = Agent(name: kind, kind: kind, status: status, sessionId: "s1", title: "Fix the build")
        return [Workspace(id: "w1", label: "web", tabs: [Tab(id: "w1:t1", label: "build", number: 1,
                          panes: [Pane(id: "w1:p1", terminalId: "term_1", cwd: "/work", agent: a)], status: status)])]
    }
    func msg(_ json: String) -> Data { Data(json.utf8) }
    func types(_ ms: [HubMessage]) -> [String] { ms.map(\.type) }
    func reply(_ ms: [HubMessage]) -> HubReply? { ms.last.flatMap { if case .reply(let r) = $0 { r } else { nil } } }
    func queued(_ ms: [HubMessage]) -> HubQueued? { ms.lazy.compactMap { if case .queued(let q) = $0 { q } else { nil } }.first }
    func pulled(_ ms: [HubMessage]) -> HubPulled? { ms.lazy.compactMap { if case .pulled(let p) = $0 { p } else { nil } }.first }
    let devices = MemoryDeviceStore()
    devices.add(token: "tok-read", device: HubDevice(id: "d-read", name: "Phone", level: .read))
    devices.add(token: "tok-input", device: HubDevice(id: "d-input", name: "Tablet", level: .input))
    func session(_ b: FakeHubBackend, token: String = "tok-input") async -> HubSession {
        let s = HubSession(backend: b, devices: devices)
        _ = await s.receive(msg(#"{"v":1,"type":"hello","id":"h","token":"\#(token)","client":"test","clientVersion":"1"}"#))
        return s
    }
    let pull = msg(#"{"v":1,"type":"pullQueued","id":"q1","pane":"w1:p1"}"#)

    // The push.
    do {
        let b = FakeHubBackend(workspaces: ws(.working))
        b.screens["w1:p1"] = screen(["QC reply GAMMA", "QD reply DELTA"])
        b.queuedLogs["s1"] = ["QC reply GAMMA", nil]
        let s = await session(b)
        let w = await s.receive(msg(#"{"v":1,"type":"watch","id":"c1","pane":"w1:p1"}"#))
        let q = queued(w)
        check(q?.items == ["QC reply GAMMA", "QD reply DELTA"] && q?.pullable == true && q?.pullsAll == true && q?.agent == "claude",
              "hub queue: watch pushes the queue; the log's missing text comes from the screen (\(String(describing: q)))")
        check(await s.tick().isEmpty, "hub queue: no change, no push")
        b.screens["w1:p1"] = screen(["QC reply GAMMA", "QD reply DELTA"], input: "❯ typing")
        check(queued(await s.tick())?.pullable == false, "hub queue: text typed in the agent: not pullable, pushed")
        b.screens["w1:p1"] = "⏺ Done\n" + rule + "\n❯ \n" + rule
        let gone = queued(await s.tick())
        check(gone?.items == [], "hub queue: the queue went in: an empty push clears it (\(String(describing: gone)))")
        check(await s.tick().isEmpty, "hub queue: still empty, no push")
        let calm = FakeHubBackend(workspaces: ws(.idle))
        calm.screens["w1:p1"] = "⏺ Done"
        let c = await session(calm)
        check(queued(await c.receive(msg(#"{"v":1,"type":"watch","id":"c1","pane":"w1:p1"}"#))) == nil, "hub queue: no queue, no push on watch")
    }

    // Pulling back.
    do {
        let b = FakeHubBackend(workspaces: ws(.working))
        b.screens["w1:p1"] = screen(["QC reply GAMMA"])
        let r = await session(b, token: "tok-read")
        check(reply(await r.receive(pull))?.error?.code == .readOnly && b.pulls.isEmpty, "hub queue: a read-only device cannot pull; nothing sent")
        let s = await session(b)
        b.pullOutcome = .pulled("QC reply GAMMA")
        let out = await s.receive(pull)
        check(pulled(out) == HubPulled(pane: "w1:p1", text: "QC reply GAMMA", interrupted: false) && reply(out)?.ok == true && types(out).last == "reply",
              "hub queue: pullQueued -> pulled (the text for the composer), reply ok (\(types(out)))")
        check(b.pulls == ["w1:p1 s1"], "hub queue: the backend pulls with the agent the hub checked")
        b.pullOutcome = .interrupted("QC reply GAMMA")
        let i = await s.receive(pull)
        check(pulled(i)?.interrupted == true && pulled(i)?.text == "QC reply GAMMA" && reply(i)?.ok == true, "hub queue: the turn stopped: pulled with interrupted, the text still comes back")
        b.pullOutcome = .refused("The agent's input box is not empty. Nothing was sent.")
        let f = await s.receive(pull)
        check(pulled(f) == nil && reply(f)?.ok == false && reply(f)?.error?.message.contains("Nothing was sent") == true, "hub queue: refused -> error with the reason")
        b.pullOutcome = .failed("The text is still in the agent's input box. Check the agent's terminal.")
        check(reply(await s.receive(pull))?.error?.code == .failed, "hub queue: failed -> error")

        let pulls = b.pulls.count
        b.screens["w1:p1"] = screen(["QC reply GAMMA"], input: "❯ typing")
        check(reply(await s.receive(pull))?.ok == false && b.pulls.count == pulls, "hub queue: input box not empty: refused by the hub, the backend not called")
        b.screens["w1:p1"] = "⏺ Done"
        check(reply(await s.receive(pull))?.ok == false && b.pulls.count == pulls, "hub queue: no queue: refused, backend not called")
        b.screens["w1:p1"] = screen(["QC reply GAMMA"])
        b.writesEnabled = false
        check(reply(await s.receive(pull))?.error?.code == .readOnly && b.pulls.count == pulls, "hub queue: Allow input off: refused")
        b.writesEnabled = true
        let other = await session(FakeHubBackend(workspaces: ws(.working, kind: "pi")))
        check(reply(await other.receive(pull))?.ok == false, "hub queue: an agent without a queue Flockbook reads: refused")
    }

    // Wire format.
    let q = HubQueued(pane: "w1:p1", agent: "codex", items: ["a", nil], pullable: true, pullsAll: false)
    let back = try Hub.decodeHub(try Hub.encode(HubMessage.queued(q)))
    check(back == .queued(q), "hub queue: queued round-trips")
    let p = HubPulled(pane: "w1:p1", text: "a\nb", interrupted: true)
    check(try Hub.decodeHub(try Hub.encode(HubMessage.pulled(p))) == .pulled(p), "hub queue: pulled round-trips")
    check(try Hub.decodeClient(pull).body == .pullQueued(pane: "w1:p1"), "hub queue: pullQueued decodes")
}
