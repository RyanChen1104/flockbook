import Foundation
@testable import HerdrKit

// Fourth review: every key of a remote answer, approval and send is gated (agent identity, level now), and the
// last read before the key is the screen.
@MainActor func checksHubReview4() async throws {
    let fake = FakeHerdr(path: NSTemporaryDirectory() + "hkr4-\(getpid()).sock")
    try fake.start()
    defer { fake.kill() }
    let client = HerdrClient(session: HerdrSession(name: "fake", socketPath: fake.path))
    func agents(_ session: String, kind: String = "claude", status: String = "blocked") -> String {
        #"[{"pane_id":"w1:p1","agent":"\#(kind)","name":"\#(kind)","agent_status":"\#(status)","agent_session":{"agent":"\#(kind)","kind":"id","source":"herdr:\#(kind)","value":"\#(session)"}}]"#
    }
    let seen = Agent(name: "claude", kind: "claude", status: .blocked, sessionId: "s1", title: "")
    let keyMethods: Set<String> = ["pane.send_keys", "pane.send_text", "pane.send_input"]
    func keys(after n: Int) -> [String] { fake.requests.dropFirst(n).map(\.method).filter { keyMethods.contains($0) } }
    final class Budget: @unchecked Sendable { var left: Int; init(_ n: Int) { left = n } }
    func gate(_ yes: Int) -> (KeyGate, Budget) {
        let b = Budget(yes)
        return (KeyGate(agent: seen, allowed: { b.left -= 1; return b.left >= 0 }), b)
    }

    // passes: agent, screen, level; the screen read is the last call before the answer.
    do {
        fake.agents = agents("s1"); fake.screen = "ready"
        let n = fake.requests.count
        check(await client.passes(KeyGate(agent: seen, allowed: { true }), paneId: "w1:p1", screen: { $0 == "ready" }), "r4 gate: same agent, screen ok, allowed -> passes")
        check(fake.requests.dropFirst(n).last?.method == "pane.read", "r4 gate: the screen is read last (\(fake.requests.dropFirst(n).map(\.method)))")
        check(await !client.passes(KeyGate(agent: seen, allowed: { true }), paneId: "w1:p1", screen: { $0 == "other" }), "r4 gate: screen changed -> no")
        check(await !client.passes(KeyGate(agent: seen, allowed: { false }), paneId: "w1:p1"), "r4 gate: level gone -> no")
        fake.agents = agents("s2")
        check(await !client.passes(KeyGate(agent: seen, allowed: { true }), paneId: "w1:p1"), "r4 gate: another session in the pane -> no")
        fake.agents = agents("s1", kind: "codex")
        check(await !client.passes(KeyGate(agent: seen, allowed: { true }), paneId: "w1:p1"), "r4 gate: another agent kind -> no")
        fake.agents = "[]"
        check(await !client.passes(KeyGate(agent: seen, allowed: { true }), paneId: "w1:p1"), "r4 gate: no agent -> no")
    }

    // Approve: no key when the agent changed or the level went; sent when all holds.
    do {
        let box = """
         Bash command
         npm run build
         Do you want to proceed?
         ❯ 1. Yes
           2. No

         Esc to cancel · Tab to amend
        """
        fake.screen = box
        let id = ApprovalNotice.screenPrompt(box) ?? ""
        fake.agents = agents("s2")
        var n = fake.requests.count
        let r1 = try await client.respondIfOpen(paneId: "w1:p1", prompt: id, allow: true, agentKind: "claude", blocked: true, pending: nil,
                                                gate: KeyGate(agent: seen, allowed: { true }))
        check(!r1 && keys(after: n).isEmpty, "r4 approve: agent swapped -> nothing sent")
        fake.agents = agents("s1")
        n = fake.requests.count
        let r2 = try await client.respondIfOpen(paneId: "w1:p1", prompt: id, allow: true, agentKind: "claude", blocked: true, pending: nil,
                                                gate: KeyGate(agent: seen, allowed: { false }))
        check(!r2 && keys(after: n).isEmpty, "r4 approve: level gone -> nothing sent")
        n = fake.requests.count
        let r3 = try await client.respondIfOpen(paneId: "w1:p1", prompt: id, allow: true, agentKind: "claude", blocked: true, pending: nil,
                                                gate: KeyGate(agent: seen, allowed: { true }))
        let tail = fake.requests.dropFirst(n).map(\.method)
        check(r3 && keys(after: n) == ["pane.send_text"], "r4 approve: all holds -> one key sent")
        check(tail.count >= 2 && tail[tail.count - 2] == "pane.read", "r4 approve: the screen read is right before the key (\(tail))")
    }

    // Answer: a multi-select question needs several keys; the gate is asked before each.
    do {
        let multi = """
        ←  ☒ Tops  ✔ Submit  →
        Which toppings?
        ❯ 1. [ ] Cheese
          2. [ ] Olive
          3. [ ] Type something
             Submit
        ────────────────────
          4. Chat about this
        """
        fake.screen = multi
        fake.agents = agents("s1")
        guard let shown = QuestionAdapter.claudeScreen(multi) else { check(false, "r4 answer: fixture parses"); return }
        let q = QuestionAdapter.screenRequest(headers: shown.headers, questions: [shown.question])
        let ans = [QuestionAnswer(picks: [0, 1])]
        let total = (try? QuestionAdapter.steps(for: q, answers: ans))?.filter { if case .waitFor = $0 { false } else { true } }.count ?? 0
        check(total >= 2, "r4 answer: the fixture needs \(total) key steps")
        var n = fake.requests.count
        let (g1, _) = gate(1)
        var stopped = false
        do { try await client.answerQuestion(paneId: "w1:p1", request: q, answers: ans, gate: g1) } catch is KeyGateStop { stopped = true } catch {}
        check(stopped && keys(after: n).count == 1, "r4 answer: level gone after the first key -> stops, 1 key sent (\(keys(after: n).count))")
        fake.agents = agents("s9")
        n = fake.requests.count
        stopped = false
        do { try await client.answerQuestion(paneId: "w1:p1", request: q, answers: ans, gate: KeyGate(agent: seen, allowed: { true })) } catch is KeyGateStop { stopped = true } catch {}
        check(stopped && keys(after: n).isEmpty, "r4 answer: another agent session -> nothing sent")
        // Load all questions (navigation keys) is gated too.
        fake.agents = agents("s1")
        let two = """
        ←  ☐ Color  ☐ Size  ✔ Submit  →
        Pick a color?
        ❯ 1. Red
          2. Blue
          3. Type something.
        ────────────────────
          4. Chat about this
        """
        fake.screen = two
        n = fake.requests.count
        stopped = false
        do { _ = try await client.loadAllQuestions(paneId: "w1:p1", gate: KeyGate(agent: seen, allowed: { false })) } catch is KeyGateStop { stopped = true } catch {}
        check(stopped && keys(after: n).isEmpty, "r4 load: level gone -> no navigation keys")
    }
}
