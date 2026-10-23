import Foundation
@testable import HerdrKit

// Grok Build with herdr's integration: herdr names the session, so the log is found by its id (the resolver only fills
// in where herdr gives none) and a paired phone answers its question and permission cards through the key gate.
@MainActor func checksGrokRemote() async throws {
    func ws(_ sid: String?) -> [Workspace] {
        [Workspace(id: "w1", label: "w", tabs: [Tab(id: "t1", label: "t", number: 1, panes: [
            Pane(id: "w1:p1", terminalId: "x", cwd: "/w/proj", agent: Agent(name: "grok", kind: "grok", status: .blocked, sessionId: sid, title: "g"))
        ], status: .blocked)])]
    }
    let found = "/h/.grok/sessions/%2Fw%2Fproj/g-old/updates.jsonl"
    let named = HerdrStore.withFallbacks(ws("g1"), resolved: ["w1:p1": found], swaps: [:], leads: [])[0].tabs[0].panes[0].agent
    check(named?.sessionId == "g1" && named?.sessionResolved == false, "grok remote: herdr's session first, not the resolver's log")
    let filled = HerdrStore.withFallbacks(ws(nil), resolved: ["w1:p1": found], swaps: [:], leads: [])[0].tabs[0].panes[0].agent
    check(filled?.sessionId == found && filled?.sessionResolved == true, "grok remote: the resolver fills in without herdr's session")

    let q = QuestionRequest(toolUseId: "call-q-0", agent: "grok", questions: [
        .init(header: "", text: "Which color?", options: [.init(label: "Red", detail: "Warm."), .init(label: "Blue", detail: "Cool.")]),
        .init(header: "", text: "Which size?", options: [.init(label: "Small", detail: "Little."), .init(label: "Large", detail: "Big.")]),
    ])
    let agent = Agent(name: "grok", kind: "grok", status: .blocked, sessionId: "g1", title: "")
    check(!Hub.answerOnMac(q, agent: agent) && HubQuestion(q, paneAgent: agent).onMac == nil, "grok remote: the phone answers with herdr's session")
    check(Hub.answerOnMac(q, agent: filled) && HubQuestion(q, paneAgent: filled).onMac == true, "grok remote: a resolved log: the Mac only")

    let fake = FakeHerdr(path: NSTemporaryDirectory() + "hkgr-\(getpid()).sock")
    try fake.start()
    defer { fake.kill() }
    let client = HerdrClient(session: HerdrSession(name: "fake", socketPath: fake.path))
    func agents(_ session: String) -> String {
        #"[{"pane_id":"w1:p1","agent":"grok","name":"grok","agent_status":"blocked","agent_session":{"agent":"grok","kind":"id","source":"herdr:grok","value":"\#(session)"}}]"#
    }
    func input(_ p: [String: Any]) -> [String] { (p["keys"] as? [String]) ?? [(p["text"] as? String) ?? ""] }
    let idle = "  ╭──────╮\n  │ ❯    │\n  ╰──────╯\n  Shift+Tab:mode  │  Ctrl+.:shortcuts"

    // The question card: a digit per question, each only while that question is on screen for this agent.
    func picker(_ text: String, _ rows: [(String, String)], at k: Int) -> String {
        var l = ["  ┃", "  ┃  \(text)", "  ┃"]
        for (i, r) in rows.enumerated() { l.append("  ┃  \(i + 1) (○) \(r.0)  \(r.1)") }
        l += ["  ┃  z (○) Type your answer here", "  ┃", "  ┃  [\(k)/2] ↑/↓ navigate · ←/→ question · y copy  \(k == 2 ? "Enter:submit" : "Enter:select")",
              "  ┃", "", "  Tab:next answer  │  Esc:scrollback  │  Shift+x:dismiss"]
        return l.joined(separator: "\n")
    }
    let q1 = picker("Which color?", [("Red", "Warm."), ("Blue", "Cool.")], at: 1), q2 = picker("Which size?", [("Small", "Little."), ("Large", "Big.")], at: 2)
    do {
        fake.agents = agents("g1"); fake.screen = q1
        var sent: [String] = []
        fake.onInput = { _, p in
            sent += input(p)
            fake.screen = fake.screen == q1 ? q2 : idle
        }
        var err: Error?
        do { try await client.answerQuestion(paneId: "w1:p1", request: q, answers: [QuestionAnswer(picks: [1]), QuestionAnswer(picks: [0])],
                                             gate: KeyGate(agent: agent, allowed: { true })) } catch { err = error }
        check(err == nil && sent == ["2", "1"], "grok remote: the phone's answer, one digit per question \(sent) \(String(describing: err))")
        fake.screen = q1; sent = []
        fake.onInput = { _, p in sent += input(p); fake.agents = agents("g2"); fake.screen = q2 }
        err = nil
        do { try await client.answerQuestion(paneId: "w1:p1", request: q, answers: [QuestionAnswer(picks: [1]), QuestionAnswer(picks: [0])],
                                             gate: KeyGate(agent: agent, allowed: { true })) } catch { err = error }
        check(err != nil && sent == ["2"], "grok remote: another session in the pane: no next key \(sent)")
        fake.onInput = nil
    }

    // The permission card: Deny is Down, then Enter once the focus is on "No, reject"; each key gated.
    func prompt(focus: Int) -> String {
        let rows = ["Yes, and don't ask again for anything (always-approve mode)", "Yes, proceed", "No, reject (type to add feedback)", "Never allow: echo"]
        var l = ["  ┃", "  ┃  ›  Write hi into out.txt", "  ┃  │ echo hi > out.txt", "  ┃"]
        for (i, r) in rows.enumerated() { l.append("  ┃  \(i + 1) (\(i + 1 == focus ? "●" : "○")) \(r)") }
        l += ["  ┃", "", "  1/4:select  │  Tab:next option  │  ←/→:scope  │  Ctrl+o:always-approve  │  Ctrl+c:cancel  │  Esc:scrollback"]
        return l.joined(separator: "\n")
    }
    do {
        fake.agents = agents("g1"); fake.screen = prompt(focus: 2)
        let id = ApprovalNotice.promptIDs(.init(agentKind: "grok", blocked: true, pendingToolUseId: nil, screen: prompt(focus: 2)), writes: true).first ?? ""
        var sent: [String] = []
        fake.onInput = { _, p in
            let k = input(p); sent += k
            fake.screen = k == ["Down"] ? prompt(focus: 3) : idle
        }
        let denied = try await client.respondIfOpen(paneId: "w1:p1", prompt: id, allow: false, agentKind: "grok", blocked: true, pending: nil,
                                                    gate: KeyGate(agent: agent, allowed: { true }))
        check(denied && sent == ["Down", "Enter"], "grok remote: Deny = Down, then Enter \(sent)")
        fake.screen = prompt(focus: 2); sent = []
        let allowed = try await client.respondIfOpen(paneId: "w1:p1", prompt: id, allow: true, agentKind: "grok", blocked: true, pending: nil,
                                                     gate: KeyGate(agent: agent, allowed: { true }))
        check(allowed && sent == ["Enter"], "grok remote: Allow = Enter \(sent)")
        fake.screen = prompt(focus: 1); sent = []
        let off = try await client.respondIfOpen(paneId: "w1:p1", prompt: id, allow: true, agentKind: "grok", blocked: true, pending: nil,
                                                 gate: KeyGate(agent: agent, allowed: { true }))
        check(!off && sent.isEmpty, "grok remote: the focus on always-approve: nothing sent \(sent)")
        // The level goes after Down (checks: the open prompt, Down, then Enter): no Enter.
        fake.screen = prompt(focus: 2); sent = []
        final class Budget: @unchecked Sendable { var left = 2 }
        let b = Budget()
        let cut = try await client.respondIfOpen(paneId: "w1:p1", prompt: id, allow: false, agentKind: "grok", blocked: true, pending: nil,
                                                 gate: KeyGate(agent: agent, allowed: { b.left -= 1; return b.left >= 0 }))
        check(!cut && sent == ["Down"], "grok remote: the level gone between keys: no Enter \(sent)")
        fake.onInput = nil
    }
}
