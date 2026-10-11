import Foundation
@testable import HerdrKit

// Findings of the hub security review: each check failed before its fix.
@MainActor func checksHubSecurity() async throws {
    typealias N = ApprovalNotice
    func msg(_ json: String) -> Data { Data(json.utf8) }
    func code(_ ms: [HubMessage]) -> HubError.Code? { ms.last.flatMap { if case .reply(let r) = $0 { r.error?.code } else { nil } } }
    func isOK(_ ms: [HubMessage]) -> Bool { ms.last.map { if case .reply(let r) = $0 { r.ok } else { false } } ?? false }
    func box(_ command: String) -> String {
        """
        ────────────────────────────────────────
         Bash command
         Run it
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
         \(command)
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
         Do you want to proceed?
         ❯ 1. Yes
           2. No

         Esc to cancel · Tab to amend
        """
    }
    let devices = MemoryDeviceStore()
    devices.add(token: "tok", device: HubDevice(id: "d1", name: "Phone", level: .input))
    func ws(_ status: AgentStatus, agentKind: String = "claude") -> [Workspace] {
        let a = Agent(name: agentKind, kind: agentKind, status: status, sessionId: "s1", title: "t")
        return [Workspace(id: "w1", label: "w", tabs: [Tab(id: "w1:t1", label: "t", number: 1,
                          panes: [Pane(id: "w1:p1", terminalId: "term_1", cwd: "/w", agent: a), Pane(id: "w1:p2", terminalId: "term_2", cwd: "/w", agent: nil)],
                          status: status)])]
    }
    func session(_ b: FakeHubBackend) async -> HubSession {
        let s = HubSession(backend: b, devices: devices)
        _ = await s.receive(msg(#"{"v":1,"type":"hello","id":"h","token":"tok","client":"t","clientVersion":"1"}"#))
        return s
    }

    // (2) Remote input goes to agents only: a plain shell pane stays read only.
    do {
        let b = FakeHubBackend(workspaces: ws(.idle))
        b.screens["w1:p2"] = "$ "
        let s = await session(b)
        let r = await s.receive(msg(#"{"v":1,"type":"send","id":"c1","pane":"w1:p2","text":"ls"}"#))
        check(code(r) == .readOnly && b.sent.isEmpty, "security: send to a shell pane -> readOnly, nothing typed (\(String(describing: code(r))))")
        b.screens["w1:p1"] = "> "
        check(isOK(await s.receive(msg(#"{"v":1,"type":"send","id":"c2","pane":"w1:p1","text":"hi"}"#))) && b.sent.count == 1, "security: send to an agent pane still works")
    }

    // (3) Log lag: the log's pending call is A, the screen shows prompt B. An id is good only for the prompt on screen.
    do {
        let screenB = box("rm -rf build")
        let lagging = N.PaneState(agentKind: "claude", blocked: true, pendingToolUseId: "toolu_A", screen: screenB,
                                  pendingTool: "Bash", pendingCommand: "npm run build")
        check(N.prompt(lagging, writes: true) == N.screenPrompt(screenB), "security: log lags the screen -> buttons bound to the screen prompt")
        check(N.outcome(actionIdentifier: N.Action.allow.rawValue, boundPrompt: "toolu_A", now: lagging, writes: true) == .open,
              "security: an id for the log's call A does not answer screen prompt B")
        let caughtUp = N.PaneState(agentKind: "claude", blocked: true, pendingToolUseId: "toolu_B", screen: screenB,
                                   pendingTool: "Bash", pendingCommand: "rm   -rf build")
        check(N.prompt(caughtUp, writes: true) == "toolu_B", "security: the log's call matches the box (tool + command) -> its id is good")
        check(N.outcome(actionIdentifier: N.Action.allow.rawValue, boundPrompt: N.screenPrompt(screenB), now: caughtUp, writes: true) == .send(allow: true),
              "security: the screen id stays good when the log matches")
        let unknownCall = N.PaneState(agentKind: "claude", blocked: true, pendingToolUseId: "toolu_B", screen: screenB)
        check(N.prompt(unknownCall, writes: true) == N.screenPrompt(screenB), "security: a log call without tool and command is not trusted for the box")

        // The hub: a client holding A while the screen shows B.
        let b = FakeHubBackend(workspaces: ws(.blocked))
        b.items["s1"] = [ConversationItem(id: "i1", kind: .permissionRequest(PermissionRequest(title: "Bash", command: "npm run build", toolName: "Bash", toolUseId: "toolu_A")))]
        b.screens["w1:p1"] = screenB
        let s = await session(b)
        let r = await s.receive(msg(#"{"v":1,"type":"approve","id":"c1","pane":"w1:p1","prompt":"toolu_A","allow":true}"#))
        check(code(r) == .stale && b.approved.isEmpty, "security: hub approve with the lagging log id -> stale, nothing sent")
        // Re-check right before the keys: the backend refuses when the prompt changed in between.
        b.approveOK = false
        let id = N.screenPrompt(screenB) ?? ""
        let r2 = await s.receive(msg(#"{"v":1,"type":"approve","id":"c2","pane":"w1:p1","prompt":"\#(id)","allow":true}"#))
        check(code(r2) == .stale && b.approved == ["w1:p1 \(id) true"], "security: backend re-check failed -> stale (\(b.approved))")
    }

    // (3) The re-check before the keys, on the wire: reads, then sends only when the bound prompt is still open.
    do {
        let fake = FakeHerdr(path: NSTemporaryDirectory() + "hksec-\(getpid()).sock")
        try fake.start()
        defer { fake.kill() }
        let client = HerdrClient(session: HerdrSession(name: "fake", socketPath: fake.path))
        let screenA = box("npm run build")
        fake.screen = screenA
        let idA = N.screenPrompt(screenA) ?? ""
        let sent = try await client.respondIfOpen(paneId: "w1:p1", prompt: idA, allow: true, agentKind: "claude", blocked: true, pending: nil)
        check(sent && fake.requests.last?.method == "pane.send_text", "security: respondIfOpen sends when the prompt is still open")
        fake.screen = box("rm -rf /")
        let n = fake.requests.count
        let again = try await client.respondIfOpen(paneId: "w1:p1", prompt: idA, allow: true, agentKind: "claude", blocked: true, pending: nil)
        check(!again && fake.requests.dropFirst(n).allSatisfy { $0.method == "pane.read" }, "security: respondIfOpen sends nothing when another prompt is open")
    }

    // (4) Text from a client: no control characters (except newline and tab), no DEL, no C1, length capped.
    do {
        let bad = ["a\u{1b}[201~b", "a\rb", "a\u{0}b", "a\u{7f}b", "a\u{9b}b", "a\u{3}b", String(repeating: "x", count: Hub.maxSendText + 1)]
        for t in bad { check(Hub.inputProblem(t, limit: Hub.maxSendText) != nil, "security: text \(t.prefix(12).debugDescription)… refused") }
        check(Hub.inputProblem("line one\nline two\tok — ünïcode 🙂", limit: Hub.maxSendText) == nil, "security: newline, tab and Unicode are fine")
        let b = FakeHubBackend(workspaces: ws(.idle))
        b.screens["w1:p1"] = "> "
        let s = await session(b)
        let r = await s.receive(msg(#"{"v":1,"type":"send","id":"c1","pane":"w1:p1","text":"hi\u001b[201~\rrm -rf /\r"}"#))
        check(code(r) == .badRequest && b.sent.isEmpty, "security: send with ESC/CR -> badRequest, nothing typed")
        let qb = FakeHubBackend(workspaces: ws(.blocked))
        qb.screens["w1:p1"] = """
         ←  ☐ Target  ✔ Submit  →

        Which target?

        ❯ 1. Staging
          2. Production
          3. Type something.
        ──────────────────────────
          Chat about this
        """
        let qs = await session(qb)
        let w = await qs.receive(msg(#"{"v":1,"type":"watch","id":"c0","pane":"w1:p1"}"#))
        let qid = w.compactMap { if case .prompt(let p) = $0 { p.question?.id } else { nil } }.first ?? ""
        let a = await qs.receive(msg(#"{"v":1,"type":"answer","id":"c2","pane":"w1:p1","question":"\#(qid)","answers":[{"picks":[],"other":"x\u001bq"}]}"#))
        check(!qid.isEmpty && code(a) == .badRequest && qb.answered.isEmpty, "security: answer.other with ESC -> badRequest, nothing chosen")
    }

    // (5) A permission prompt the parser cannot read still counts as open (fail closed).
    do {
        let odd = "────────────────\n Do you want to make this edit?"   // the options are below the visible rows
        check(N.screenPrompt(odd) == nil, "security: (setup) the parser does not read this prompt")
        let b = FakeHubBackend(workspaces: ws(.blocked))
        b.screens["w1:p1"] = odd
        let s = await session(b)
        let r = await s.receive(msg(#"{"v":1,"type":"send","id":"c1","pane":"w1:p1","text":"hello"}"#))
        check(code(r) == .promptOpen && b.sent.isEmpty, "security: unreadable prompt on screen -> send refused (promptOpen)")
        let ap = await s.receive(msg(#"{"v":1,"type":"approve","id":"c2","pane":"w1:p1","prompt":"x","allow":true}"#))
        check(code(ap) == .stale && b.approved.isEmpty, "security: unreadable prompt -> approve stale")
        // Prose that merely asks is not a prompt: an idle agent's last line.
        let idle = FakeHubBackend(workspaces: ws(.idle))
        idle.screens["w1:p1"] = "Done. Do you want me to open a PR?\n\n> "
        let si = await session(idle)
        check(isOK(await si.receive(msg(#"{"v":1,"type":"send","id":"c3","pane":"w1:p1","text":"yes"}"#))), "security: an idle agent asking in prose still takes a message")
    }

    // (7) Revoke closes that device's live connections at once.
    do {
        let b = FakeHubBackend(workspaces: ws(.idle))
        let ds = MemoryDeviceStore()
        ds.add(token: "t1", device: HubDevice(id: "d1", name: "A", level: .read))
        ds.add(token: "t2", device: HubDevice(id: "d2", name: "B", level: .read))
        let server = HubServer(backend: b, devices: ds, tickInterval: .seconds(30))
        let port = try await server.start(host: "127.0.0.1", port: 0)
        let c1 = HubTestClient(port: port), c2 = HubTestClient(port: port)
        try await c1.send(#"{"v":1,"type":"hello","id":"h","token":"t1","client":"t","clientVersion":"1"}"#)
        try await c2.send(#"{"v":1,"type":"hello","id":"h","token":"t2","client":"t","clientVersion":"1"}"#)
        _ = await c1.untilReply(); _ = await c2.untilReply()
        ds.revoke(device: "d1")
        server.dropRevoked()
        try? await Task.sleep(for: .milliseconds(300))
        check(server.connectionCount == 1, "security: revoke closes the device's connection at once (\(server.connectionCount) left)")
        try? await c2.send(#"{"v":1,"type":"ping","id":"p"}"#)
        check(await c2.untilReply().last.map { if case .reply(let r) = $0 { r.ok } else { false } } == true, "security: other devices stay connected")
        c1.close(); c2.close(); server.stop()
    }

    // (8) Wrong pairing tries count per source: one peer cannot burn the owner's offer; a global cap stays.
    do {
        let p = HubPairing(devices: MemoryDeviceStore())
        let o = p.offer()
        for i in 0..<10 { _ = p.redeem("wrong \(i)", name: "x", source: "10.0.0.66") }
        check(p.open == o, "security: one peer's wrong tries leave the offer open")
        check(p.redeem(o.secret, name: "x", source: "10.0.0.66") == nil, "security: that peer is refused for this offer, even with the secret")
        check(p.redeem(o.code, name: "Phone", source: "100.64.0.7") != nil, "security: the owner's phone still pairs")
        let o2 = p.offer()
        for i in 0..<HubPairing.maxTries { _ = p.redeem("w\(i)", name: "x", source: "peer-\(i)") }
        check(p.open == nil && p.redeem(o2.secret, name: "x", source: "owner") == nil, "security: \(HubPairing.maxTries) wrong tries in all end the offer")
    }
}
