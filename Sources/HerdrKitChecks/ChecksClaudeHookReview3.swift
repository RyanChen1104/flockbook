import Foundation
@testable import HerdrKit

// Review round 3 on 3eaa268: red first.
@MainActor func checksClaudeHookReview3() async throws {
    // P2: two questions of one request that look the same once whitespace is dropped ("Deploy A B?", "Deploy AB?",
    // same options): the screen cannot say which one is open, so no key goes (question 1's digit could land on 2).
    let q = ClaudeQuestionHook.record(Data(#"{"session_id":"s3","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"toolu_r3","tool_input":{"questions":[{"question":"Deploy A B?","header":"Spaced","multiSelect":false,"options":[{"label":"Yes","description":"go"},{"label":"No","description":"stop"}]},{"question":"Deploy AB?","header":"Joined","multiSelect":false,"options":[{"label":"Yes","description":"go"},{"label":"No","description":"stop"}]}]}}"#.utf8), time: Date())!.request
    let sim = ClaudePickerSim([.init(header: "Spaced", text: "Deploy A B?", options: [("Yes", "go"), ("No", "stop")], multi: false),
                               .init(header: "Joined", text: "Deploy AB?", options: [("Yes", "go"), ("No", "stop")], multi: false)])
    sim.at = 1
    check(!QuestionAdapter.shows(q, question: 0, screen: sim.render()), "r3 P2: question 2 on screen does not pass as question 1 when they look alike")
    sim.at = 0
    check(!QuestionAdapter.shows(q, question: 0, screen: sim.render()), "r3 P2: two questions alike -> neither is proven on screen")
    let fake = FakeHerdr(path: NSTemporaryDirectory() + "hkB3-\(getpid()).sock")
    try fake.start()
    defer { fake.kill() }
    let client = HerdrClient(session: HerdrSession(name: "fake", socketPath: fake.path))
    fake.agents = #"[{"pane_id":"w1:p1","agent":"claude","name":"claude","agent_status":"blocked","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"s3"}}]"#
    fake.screen = sim.render()
    let n = fake.requests.count
    var err: Error?
    do { try await client.answerQuestion(paneId: "w1:p1", request: q, answers: [QuestionAnswer(picks: [0]), QuestionAnswer(picks: [1])],
                                         gate: KeyGate(agent: Agent(name: "c", kind: "claude", status: .blocked, sessionId: "s3", title: ""), allowed: { true })) } catch { err = error }
    check(err != nil && !fake.requests.dropFirst(n).contains { ["pane.send_keys", "pane.send_text"].contains($0.method) },
          "r3 P2: questions alike -> refused before any key")
    // Distinct questions still pass.
    let ok = ClaudePickerSim([.init(header: "Spaced", text: "Deploy A?", options: [("Yes", "go"), ("No", "stop")], multi: false),
                              .init(header: "Joined", text: "Deploy B?", options: [("Yes", "go"), ("No", "stop")], multi: false)])
    var q2 = q
    q2.questions[0].text = "Deploy A?"; q2.questions[1].text = "Deploy B?"
    check(QuestionAdapter.shows(q2, question: 0, screen: ok.render()), "r3 P2: distinct questions -> question 1 is proven")
}
