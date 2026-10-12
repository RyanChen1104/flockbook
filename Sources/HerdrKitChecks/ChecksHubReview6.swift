import Foundation
@testable import HerdrKit

// Sixth review: a question matches only with its options exactly (order, no new ones, the same mode), the hub's
// full read stays bound to the request the client answered, and the Codex picker counts as a prompt for text.
@MainActor func checksHubReview6() async throws {
    let fake = FakeHerdr(path: NSTemporaryDirectory() + "hkr6-\(getpid()).sock")
    try fake.start()
    defer { fake.kill() }
    let client = HerdrClient(session: HerdrSession(name: "fake", socketPath: fake.path))
    fake.agents = #"[{"pane_id":"w1:p1","agent":"codex","name":"codex","agent_status":"blocked","agent_session":{"agent":"codex","kind":"id","source":"herdr:codex","value":"s1"}}]"#
    let seen = Agent(name: "codex", kind: "codex", status: .blocked, sessionId: "s1", title: "")
    let open = KeyGate(agent: seen, allowed: { true })
    let keyMethods: Set<String> = ["pane.send_keys", "pane.send_text", "pane.send_input"]
    func keys(after n: Int) -> Int { fake.requests.dropFirst(n).filter { keyMethods.contains($0.method) }.count }
    func opt(_ s: String) -> QuestionRequest.Option { .init(label: s) }

    // Codex 0.162 picker, as captured live.
    let codex = """
    › Ask me two questions
      Question 1/2 (2 unanswered)
      Pick a color?

      › 1. Red                r
        2. Blue               b
        3. None of the above  Optionally, add details in notes (tab)

      tab to add notes | enter to submit answer | ←/→ to navigate questions | esc to interrupt
    """
    let notes = """
      Question 1/2 (2 unanswered)
      Pick a color?

        1. Red                r
        2. Blue               b
      › 3. None of the above  Optionally, add details in notes (tab)

      › fish note

      tab or esc to clear notes | enter to submit answer
    """
    var cq = QuestionRequest(toolUseId: "call_1", agent: "codex", questions: [
        .init(header: "Color", text: "Pick a color?", options: [opt("Red"), opt("Blue")], multiSelect: false),
        .init(header: "Size", text: "Pick a size?", options: [opt("Small"), opt("Large")], multiSelect: false)], headers: [])
    cq.state = .pending
    let swapped = codex.replacingOccurrences(of: "1. Red                r", with: "1. Blue               b")
        .replacingOccurrences(of: "2. Blue               b", with: "2. Red                r")
    let added = codex.replacingOccurrences(of: "3. None of the above", with: "3. Green              g\n    4. None of the above")
    let emptyNotes = notes.replacingOccurrences(of: "› fish note", with: "› Add notes")
    check(QuestionAdapter.shows(cq, question: 0, screen: codex), "r6 codex: the captured picker matches")
    // Notes open: a digit would be typed into them. Only the notes state the hub made matches (live captures).
    check(!QuestionAdapter.shows(cq, question: 0, screen: notes) && !QuestionAdapter.shows(cq, question: 0, screen: emptyNotes),
          "r6 codex: notes open (typed or empty) -> not a pick screen")
    check(QuestionAdapter.shows(cq, question: 0, screen: emptyNotes, other: "") && QuestionAdapter.shows(cq, question: 0, screen: notes, other: "fish note")
          && !QuestionAdapter.shows(cq, question: 0, screen: notes, other: "cat"), "r6 codex: the notes the hub opened or typed match")
    fake.screen = notes
    var nn = fake.requests.count
    do { try await client.answerQuestion(paneId: "w1:p1", request: cq, answers: [QuestionAnswer(picks: [0]), QuestionAnswer(picks: [0])], gate: open) } catch {}
    check(keys(after: nn) == 0, "r6 codex: notes open -> a pick gets no key (\(keys(after: nn)))")
    fake.screen = codex
    fake.onInput = { method, params in
        if method == "pane.send_keys", (params["keys"] as? [String]) == ["Tab"] { fake.screen = emptyNotes }
        if method == "pane.send_text" || method == "pane.send_input", fake.screen == emptyNotes { fake.screen = notes.replacingOccurrences(of: "fish note", with: "cat") }
    }
    nn = fake.requests.count
    do { try await client.answerQuestion(paneId: "w1:p1", request: cq, answers: [QuestionAnswer(other: "cat"), QuestionAnswer(picks: [0])], gate: open) } catch {}
    let sentKeys = fake.requests.dropFirst(nn).filter { keyMethods.contains($0.method) }.map { ($0.params["keys"] as? [String])?.joined() ?? "text" }
    check(sentKeys.suffix(3) == ["Tab", "text", "Enter"], "r6 codex: notes answer goes Tab, text, Enter through the gate (\(sentKeys))")
    fake.onInput = nil
    check(!QuestionAdapter.shows(cq, question: 0, screen: swapped), "r6 codex: options in another order -> not this question")
    check(!QuestionAdapter.shows(cq, question: 0, screen: added), "r6 codex: a new option -> not this question")
    var cm = cq; cm.questions[0].multiSelect = true
    check(!QuestionAdapter.shows(cm, question: 0, screen: codex), "r6 codex: another mode (multiSelect) -> not this question")
    fake.screen = swapped
    var n = fake.requests.count
    do { try await client.answerQuestion(paneId: "w1:p1", request: cq, answers: [QuestionAnswer(picks: [0]), QuestionAnswer(picks: [0])], gate: open) } catch {}
    check(keys(after: n) == 0, "r6 codex: swapped options get no key (\(keys(after: n)))")

    // Claude: no new trailing option; the typed "Other" row only with the text we typed; the same mode.
    let claude = """
    ←  ☐ Color  ✔ Submit  →
    Pick a color?
    ❯ 1. Red
         Choose Red
      2. Blue
         Choose Blue
      3. Type something.
    ────────────────────
      4. Chat about this
    Enter to select · ↑/↓ to navigate · Esc to cancel
    """
    let typed = claude.replacingOccurrences(of: "3. Type something.", with: "3. Green typed")
    let extra = claude.replacingOccurrences(of: "3. Type something.", with: "3. Green\n  4. Type something.")
    let one = QuestionAdapter.screenRequest(headers: ["Color"], questions: [.init(header: "Color", text: "Pick a color?", options: [opt("Red"), opt("Blue")], multiSelect: false)])
    check(QuestionAdapter.shows(one, question: 0, screen: claude), "r6 claude: the picker matches")
    check(!QuestionAdapter.shows(one, question: 0, screen: extra), "r6 claude: a new trailing option -> not this question")
    check(!QuestionAdapter.shows(one, question: 0, screen: typed) && QuestionAdapter.shows(one, question: 0, screen: typed, other: "Green typed"),
          "r6 claude: the typed row only with our own text")
    // Live 2.1.296: text typed into the "Other" row replaces "Type something." The row is not an option, and a
    // digit pick there would be typed into it: a request read from such a screen gets no key.
    check(QuestionAdapter.claudeScreen(typed)?.question.options.map(\.label) == ["Red", "Blue"], "r6 claude: the typed row is not read as an option")
    let multiTyped = "←  ☐ Tops  ✔ Submit  →\nWhich toppings?\n  1. [ ] Cheese\n  2. [ ] Olive\n❯ 3. [ ] ham please\n     Submit\n────\n  4. Chat about this"
    check(QuestionAdapter.claudeScreen(multiTyped)?.question.options.map(\.label) == ["Cheese", "Olive"], "r6 claude: the typed row (multi) is not an option")
    fake.agents = #"[{"pane_id":"w1:p1","agent":"claude","name":"claude","agent_status":"blocked","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"s1"}}]"#
    fake.screen = typed
    if let shown = QuestionAdapter.claudeScreen(typed) {
        let fromScreen = QuestionAdapter.screenRequest(headers: shown.headers, questions: [shown.question])
        n = fake.requests.count
        do { try await client.answerQuestion(paneId: "w1:p1", request: fromScreen, answers: [QuestionAnswer(picks: [0])],
                                             gate: KeyGate(agent: Agent(name: "claude", kind: "claude", status: .blocked, sessionId: "s1", title: ""), allowed: { true })) } catch {}
        check(keys(after: n) == 0, "r6 claude: text in the Other row -> a pick gets no key (\(keys(after: n)))")
    } else { check(false, "r6 claude: the typed screen parses") }
    // Review 7 (0463fe2): the hub's question id covers what the card showed; "Type something" prefixes are options;
    // Codex marks a recommended option on screen.
    let rb = QuestionAdapter.screenRequest(headers: ["Color"], questions: [.init(header: "Color", text: "Pick a color?", options: [opt("Red"), opt("Blue")], multiSelect: false)])
    let rg = QuestionAdapter.screenRequest(headers: ["Color"], questions: [.init(header: "Color", text: "Pick a color?", options: [opt("Red"), opt("Green")], multiSelect: false)])
    var rbm = rb; rbm.questions[0].multiSelect = true
    check(rb.toolUseId == rg.toolUseId && Hub.questionID(rb) != Hub.questionID(rg) && Hub.questionID(rb) != Hub.questionID(rbm) && Hub.questionID(rb) == Hub.questionID(rb),
          "r7 id: same screen id, other options or mode -> another hub id")
    check(Hub.questionID(cq) == "call_1" && HubQuestion(rb).id == Hub.questionID(rb), "r7 id: log ids unchanged; the pushed card carries the hub id")
    let prefixed = claude.replacingOccurrences(of: "  3. Type something.", with: "  3. Type something else\n  4. Type something.")
    check(QuestionAdapter.claudeScreen(prefixed)?.question.options.map(\.label) == ["Red", "Blue", "Type something else"], "r7 claude: an option starting with 'Type something' is an option")
    check(QuestionAdapter.claudeScreen(claude.replacingOccurrences(of: "────────────────────\n", with: "")) == nil, "r7 claude: no line above 'Chat about this' -> not read")
    let recommended = codex.replacingOccurrences(of: "1. Red                r", with: "1. Red (Recommended)  r")
    var cr = cq; cr.questions[0].options[0].recommended = true
    check(QuestionAdapter.shows(cr, question: 0, screen: recommended) && !QuestionAdapter.shows(cr, question: 0, screen: recommended.replacingOccurrences(of: "Red (Recommended)", with: "Rose (Recommended)")),
          "r7 codex: a recommended option matches with its mark")
    // Review 8 (9aa6a8c): the key line is the last line, not any text holding its words; the Other row keeps its
    // raw text; an Other answer equal to its own digit still moves the field state on.
    let footerNote = notes.replacingOccurrences(of: "› fish note", with: "› enter to submit")
    check(!QuestionAdapter.shows(cq, question: 0, screen: footerNote) && QuestionAdapter.shows(cq, question: 0, screen: footerNote, other: "enter to submit"),
          "r8 codex: notes holding 'enter to submit' are notes, not the key line")
    let recTyped = claude.replacingOccurrences(of: "3. Type something.", with: "3. Type something. (Recommended)")
    check(QuestionAdapter.claudeParse(recTyped)?.typed == "Type something. (Recommended)" && !QuestionAdapter.shows(one, question: 0, screen: recTyped),
          "r8 claude: Other text with a (Recommended) mark is text, not the empty row")
    check(!QuestionAdapter.shows(one, question: 0, screen: claude.replacingOccurrences(of: "3. Type something.", with: "3. fish (Recommended)"), other: "fish"),
          "r8 claude: Other text 'fish (Recommended)' is not our 'fish'")
    fake.agents = #"[{"pane_id":"w1:p1","agent":"claude","name":"claude","agent_status":"blocked","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"s1"}}]"#
    fake.screen = claude
    final class Typed: @unchecked Sendable { var n = 0 }
    let typedCount = Typed()
    fake.onInput = { method, _ in
        if method == "pane.send_text" { typedCount.n += 1; if typedCount.n == 2 { fake.screen = claude.replacingOccurrences(of: "3. Type something.", with: "3. 3") } }
        if method == "pane.send_keys" { fake.screen = "❯ \n" }
    }
    nn = fake.requests.count
    do { try await client.answerQuestion(paneId: "w1:p1", request: one, answers: [QuestionAnswer(other: "3")],
                                         gate: KeyGate(agent: Agent(name: "claude", kind: "claude", status: .blocked, sessionId: "s1", title: ""), allowed: { true })) } catch {}
    let digitOther = fake.requests.dropFirst(nn).filter { keyMethods.contains($0.method) }.map { ($0.params["keys"] as? [String])?.joined() ?? "text" }
    check(digitOther == ["text", "text", "Enter"], "r8 claude: Other text equal to its digit -> digit, text, Enter (\(digitOther))")
    fake.onInput = nil
    var om = one; om.questions[0].multiSelect = true
    check(!QuestionAdapter.shows(om, question: 0, screen: claude), "r6 claude: another mode (multiSelect) -> not this question")

    // (2) The hub's full read is bound to the request the client answered.
    let a = QuestionAdapter.screenRequest(headers: ["Color", "Size"], questions: [.init(header: "", text: "Pick a color?", options: [opt("Red"), opt("Blue")], multiSelect: false)])
    let bFull = QuestionAdapter.screenRequest(headers: ["Color", "Size"], questions: [
        .init(header: "Color", text: "Pick a hue?", options: [opt("Red"), opt("Blue")], multiSelect: false),
        .init(header: "Size", text: "Pick a size?", options: [opt("Small"), opt("Large")], multiSelect: false)])
    let aFull = QuestionAdapter.screenRequest(headers: ["Color", "Size"], questions: [
        .init(header: "Color", text: "Pick a color?", options: [opt("Red"), opt("Blue")], multiSelect: false),
        .init(header: "Size", text: "Pick a size?", options: [opt("Small"), opt("Large")], multiSelect: false)])
    check(QuestionAdapter.sameRequest(aFull, as: a) && !QuestionAdapter.sameRequest(bFull, as: a), "r6 full: same headers, another question -> another request")
    fake.agents = #"[{"pane_id":"w1:p1","agent":"claude","name":"claude","agent_status":"blocked","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"s1"}}]"#
    let cgate = KeyGate(agent: Agent(name: "claude", kind: "claude", status: .blocked, sessionId: "s1", title: ""), allowed: { true })
    fake.screen = claude.replacingOccurrences(of: "☐ Color  ✔ Submit", with: "☐ Color  ☐ Size  ✔ Submit").replacingOccurrences(of: "Pick a color?", with: "Pick a hue?")
    n = fake.requests.count
    var refused = false
    do { _ = try await client.loadAllQuestions(paneId: "w1:p1", gate: cgate, expect: a) } catch { refused = true }
    check(refused && keys(after: n) == 0, "r6 full: the picker now shows another request -> refused, no key (\(keys(after: n)))")

    // (3) The Codex picker takes keys: plain text is not typed into it.
    check(Hub.screenTakesKeys(codex) && Hub.screenTakesKeys(notes), "r6 text: the Codex picker counts as a prompt")
    check(!Hub.screenTakesKeys("› Ask Codex to do anything\n  ? for shortcuts"), "r6 text: the Codex composer is not a prompt")
    fake.agents = #"[{"pane_id":"w1:p1","agent":"codex","name":"codex","agent_status":"idle","agent_session":{"agent":"codex","kind":"id","source":"herdr:codex","value":"s1"}}]"#
    fake.screen = codex
    n = fake.requests.count
    let sent = await MessageSend.send("1", to: "w1:p1", client: client, kind: "codex", directory: NSTemporaryDirectory(),
                                      gate: KeyGate(agent: Agent(name: "codex", kind: "codex", status: .idle, sessionId: "s1", title: ""), allowed: { true }))
    check(!sent && keys(after: n) == 0, "r6 text: an idle snapshot but the Codex picker on screen -> not sent")
}
