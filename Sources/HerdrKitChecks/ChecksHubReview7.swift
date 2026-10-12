import Foundation
@testable import HerdrKit

// Seventh review: a remote answer goes only to a question read from the agent's log, never from the screen alone,
// and a key goes only when the picker on screen is that question's exact rendering: question text, rows with
// labels and descriptions in order, the Other row, the notes the hub typed, all compared with whitespace dropped
// (so wrapping does not count). The focus mark and the notes are checked by where they are, not by how they look.
@MainActor func checksHubReview7() async throws {
    let fake = FakeHerdr(path: NSTemporaryDirectory() + "hkr7-\(getpid()).sock")
    try fake.start()
    defer { fake.kill() }
    let client = HerdrClient(session: HerdrSession(name: "fake", socketPath: fake.path))
    fake.agents = #"[{"pane_id":"w1:p1","agent":"codex","name":"codex","agent_status":"blocked","agent_session":{"agent":"codex","kind":"id","source":"herdr:codex","value":"s1"}}]"#
    let gate = KeyGate(agent: Agent(name: "codex", kind: "codex", status: .blocked, sessionId: "s1", title: ""), allowed: { true })
    let keyMethods: Set<String> = ["pane.send_keys", "pane.send_text", "pane.send_input"]
    func sent(after n: Int) -> [String] {
        fake.requests.dropFirst(n).filter { keyMethods.contains($0.method) }.map { ($0.params["keys"] as? [String])?.joined(separator: ",") ?? "text" }
    }
    func logged(_ questions: String) -> QuestionRequest {
        QuestionAdapter.codex(name: "request_user_input", callId: "call_c", arguments: #"{"questions":["# + questions + "]}")!
    }
    let red = #"{"label":"Red","description":"Choose Red"}"#, blue = #"{"label":"Blue","description":"Choose Blue"}"#
    let q = logged(#"{"id":"color","header":"Color","question":"Pick a color?","options":[\#(red),\#(blue)]}"#)

    // Codex 0.162.1, captured live (c9-input-test).
    let base = """
    › Use request_user_input once with one question
      Question 1/1 (1 unanswered)
      Pick a color?

      › 1. Red                Choose Red
        2. Blue               Choose Blue
        3. None of the above  Optionally, add details in notes (tab)

      tab to add notes | enter to submit answer | esc to interrupt
    """
    let onOther = base.replacingOccurrences(of: "  › 1. Red", with: "    1. Red").replacingOccurrences(of: "    3. None", with: "  › 3. None")
    let empty = onOther.replacingOccurrences(of: "tab to add notes | enter to submit answer | esc to interrupt",
                                             with: "› Add notes\n\n  tab or esc to clear notes | enter to submit answer")
    let typed = empty.replacingOccurrences(of: "› Add notes", with: "  › ham and eggs")

    check(QuestionAdapter.shows(q, question: 0, screen: base), "r14 codex: the live picker is the logged question")
    check(QuestionAdapter.shows(q, question: 0, screen: base.replacingOccurrences(of: " (1 unanswered)", with: "")), "r14 codex: without the unanswered count")
    check(!QuestionAdapter.shows(q, question: 0, screen: base.replacingOccurrences(of: "Question 1/1", with: "Question 1/2")), "r14 codex: another question count -> no match")
    check(!QuestionAdapter.shows(q, question: 0, screen: base.replacingOccurrences(of: "Choose Red", with: "Choose Rot")), "r14 codex: a description differs -> no match")
    check(!QuestionAdapter.shows(q, question: 0, screen: base.replacingOccurrences(of: "1. Red                Choose Red", with: "1. Blue               Choose Blue")
        .replacingOccurrences(of: "2. Blue               Choose Blue", with: "2. Red                Choose Red")), "r14 codex: rows in another order -> no match")
    check(!QuestionAdapter.shows(q, question: 0, screen: base.replacingOccurrences(of: "    3. None", with: "    3. Green\n    4. None")), "r14 codex: a new row -> no match")
    check(!QuestionAdapter.shows(q, question: 0, screen: base.replacingOccurrences(of: "Choose Red", with: "2. Violet")),
          "r14 codex: '2. Violet' on screen but not in the log -> no match")
    // The same text in the log: the screen is the log's rendering, so Codex numbers the rows as the log does.
    let violet = logged(#"{"id":"color","header":"Color","question":"Pick a color?","options":[{"label":"Red","description":"2. Violet"},\#(blue)]}"#)
    check(QuestionAdapter.shows(violet, question: 0, screen: base.replacingOccurrences(of: "Choose Red", with: "2. Violet")),
          "r14 codex: '2. Violet' in the logged description -> match, the rows are the log's")
    let long = logged(#"{"id":"color","header":"Color","question":"Pick a color?","options":[{"label":"Red","description":"Choose Red, the warm colour of the sunset"},\#(blue)]}"#)
    check(QuestionAdapter.shows(long, question: 0, screen: base.replacingOccurrences(of: "Choose Red", with: "Choose Red, the warm\n                          colour of the sunset")),
          "r14 codex: a wrapped description still matches")
    check(!QuestionAdapter.shows(long, question: 0, screen: base.replacingOccurrences(of: "Choose Red", with: "Choose Red, the warm colour of…")),
          "r14 codex: a cut description -> no match")
    // The focus mark: exactly one, at the start of a row.
    check(!QuestionAdapter.shows(q, question: 0, screen: base.replacingOccurrences(of: "    2. Blue", with: "  › 2. Blue")), "r14 codex: two focus marks -> no match")
    check(!QuestionAdapter.shows(q, question: 0, screen: base.replacingOccurrences(of: "  › 1. Red", with: "    1. Red")), "r14 codex: no focus mark -> no match")
    let marky = logged(#"{"id":"color","header":"Color","question":"Pick a color?","options":[{"label":"Red","description":"› 3. None"},\#(blue)]}"#)
    let markyScreen = base.replacingOccurrences(of: "Choose Red", with: "› 3. None")
    check(QuestionAdapter.shows(marky, question: 0, screen: markyScreen) && !QuestionAdapter.shows(marky, question: 0, screen: markyScreen, row: 2),
          "r14 codex: a mark in the logged text is text: the focus is on row 1, not on row 3")
    check(QuestionAdapter.shows(q, question: 0, screen: onOther, row: 2) && !QuestionAdapter.shows(q, question: 0, screen: base, row: 2),
          "r14 codex: the focus row is where the mark is")
    // A numbered list in the question and a fake picker head in it are text of the logged question.
    let listed = logged(#"{"id":"color","header":"Color","question":"Pick one:\n  1. Violet","options":[\#(red),\#(blue)]}"#)
    check(QuestionAdapter.shows(listed, question: 0, screen: base.replacingOccurrences(of: "  Pick a color?", with: "  Pick one:\n    1. Violet")),
          "r14 codex: a numbered list in the logged question -> match")
    check(!QuestionAdapter.shows(q, question: 0, screen: base.replacingOccurrences(of: "  Pick a color?", with: "  Pick a color?\n  Question 1/1")),
          "r14 codex: a picker head inside the question text -> no match")
    let rec = logged(#"{"id":"color","header":"Color","question":"Pick a color?","options":[{"label":"Red (Recommended)","description":"Choose Red"},\#(blue)]}"#)
    check(QuestionAdapter.shows(rec, question: 0, screen: base.replacingOccurrences(of: "1. Red               ", with: "1. Red (Recommended) "))
          && !QuestionAdapter.shows(rec, question: 0, screen: base), "r14 codex: '(Recommended)' as the log has it")
    // Notes: only the state the hub made, on the row it chose.
    check(QuestionAdapter.shows(q, question: 0, screen: empty, other: "", row: 2) && !QuestionAdapter.shows(q, question: 0, screen: empty),
          "r14 codex: empty notes the hub opened")
    check(QuestionAdapter.shows(q, question: 0, screen: typed, other: "ham and eggs", row: 2) && !QuestionAdapter.shows(q, question: 0, screen: typed, other: "cat", row: 2),
          "r14 codex: notes with the hub's text only")
    check(!QuestionAdapter.shows(q, question: 0, screen: typed.replacingOccurrences(of: "tab or esc to clear notes | enter to submit answer",
                                                                               with: "tab to add notes | enter to submit answer | esc to interrupt"), other: "ham and eggs", row: 2),
          "r14 codex: a notes line with the closed key line -> no match")
    // Review a2ce1e7: a Tab inside the notes text would close the notes between two gated keys; the key line must
    // be one of Codex's captured lines exactly, not one that only starts the same way.
    check((try? QuestionAdapter.steps(for: q, answers: [QuestionAnswer(other: "x\t1")])) == nil, "r15 codex: a Tab in the Other text -> refused before any key")
    check(!QuestionAdapter.shows(q, question: 0, screen: base.replacingOccurrences(of: " | esc to interrupt", with: "")), "r15 codex: a shortened key line -> no match")
    check(!QuestionAdapter.shows(q, question: 0, screen: base.replacingOccurrences(of: "esc to interrupt", with: "esc to interrupt | q to quit")), "r15 codex: a longer key line -> no match")
    check(QuestionAdapter.shows(q, question: 0, screen: base.replacingOccurrences(of: "submit answer | esc", with: "submit answer |  esc")), "r15 codex: key line spacing does not count")
    // The last question of a set, as captured (docs/research/ask-user-question-keys.md): "enter to submit all".
    let pay = logged(#"{"id":"food","header":"Food","question":"Cat or dog?","options":[{"label":"Cat","description":"Choose Cat."},{"label":"Dog","description":"Choose Dog."}]},{"id":"pay","header":"Pay","question":"How to pay?","options":[{"label":"Card","description":"Pay by Card."},{"label":"Cash","description":"Pay by Cash."}]}"#)
    let second = """
      Question 2/2 (1 unanswered)
      How to pay?
      › 1. Card               Pay by Card.
        2. Cash               Pay by Cash.
        3. None of the above  Optionally, add details in notes (tab)
      tab to add notes | enter to submit all | ←/→ to navigate questions | esc to interrupt
    """
    check(QuestionAdapter.shows(pay, question: 1, screen: second) && !QuestionAdapter.shows(pay, question: 0, screen: second),
          "r16 codex: the last question of a set ('enter to submit all') matches, as question 2 only")
    // Live (c9-input-test, 0.162.1): notes open on question 2 of 2.
    let secondNotes = second.replacingOccurrences(of: "  › 1. Card", with: "    1. Card").replacingOccurrences(of: "    3. None", with: "  › 3. None")
        .replacingOccurrences(of: "tab to add notes | enter to submit all | ←/→ to navigate questions | esc to interrupt", with: "› ham\n  tab or esc to clear notes | enter to submit all")
    check(QuestionAdapter.shows(pay, question: 1, screen: secondNotes, other: "ham", row: 2), "r16 codex: notes open on the last question of a set")
    // A question read from the screen has no log behind it.
    var screenQ = q; screenQ.toolUseId = "screen-1"
    check(!QuestionAdapter.shows(screenQ, question: 0, screen: base), "r14 codex: a screen-read request never matches for keys")
    check(HubQuestion(q).onMac == nil, "r14 hub: a logged question can be answered from the phone")

    // Tab (opens notes on the chosen row) waits for the focus on that row: Down keys that did not move it stop there.
    fake.screen = base
    var n = fake.requests.count
    do { try await client.answerQuestion(paneId: "w1:p1", request: q, answers: [QuestionAnswer(other: "ham and eggs")], gate: gate) } catch {}
    check(!sent(after: n).contains("Tab") && !sent(after: n).contains("text"), "r14 codex: focus not on the Other row -> no Tab, no text (\(sent(after: n)))")
    // The whole notes answer, the focus moving as Codex moves it.
    fake.screen = base
    var downs = 0
    fake.onInput = { method, params in
        guard method == "pane.send_keys", let k = params["keys"] as? [String] else {
            if fake.screen == empty { fake.screen = typed }
            return
        }
        if k == ["Down"] { downs += 1; fake.screen = downs >= 2 ? onOther : base.replacingOccurrences(of: "  › 1. Red", with: "    1. Red").replacingOccurrences(of: "    2. Blue", with: "  › 2. Blue") }
        if k == ["Tab"] { fake.screen = empty }
    }
    n = fake.requests.count
    do { try await client.answerQuestion(paneId: "w1:p1", request: q, answers: [QuestionAnswer(other: "ham and eggs")], gate: gate) } catch {}
    check(sent(after: n) == ["Down", "Down", "Tab", "text", "Enter"], "r14 codex: notes answer: Down, Down, Tab, text, Enter (\(sent(after: n)))")
    fake.onInput = nil
}
