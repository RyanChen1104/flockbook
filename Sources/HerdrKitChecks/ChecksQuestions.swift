import Foundation
@testable import HerdrKit

// Questions: AskUserQuestion, Codex request_user_input, screen picker, answer keys.

// AskUserQuestion: a question card (never a permission), answers from toolUseResult or the result text, declined on error
@MainActor func checksAskUserQuestion() async throws {
    do {
        let ql = String(decoding: fixture("question.jsonl"), as: UTF8.self).split(separator: "\n").map(String.init)
        let items = SessionLog.parse(lines: ql)
        check(describe(items) == ["asst:One question first.", "q:Branch", "q:Cleanup|Report", "q:Go", "asst:Last one.", "q:Ship"],
              "question: items \(describe(items))")
        func q(_ i: Int) -> QuestionRequest? { if case .question(let r) = items[i].kind { return r }; return nil }
        let q1 = q(1), q2 = q(2)
        check(q1?.questions[0].options.map(\.label) == ["integration", "main"] && q1?.questions[0].options.map(\.recommended) == [true, false],
              "question: (Recommended) suffix removed and flagged")
        check(q1?.questions[0].options[0].detail == "Has the latest merged work." && q1?.questions[0].multiSelect == false, "question: detail, single select")
        check(q1?.state == .answered(["integration (Recommended)"]), "question: answers from toolUseResult")
        check(q2?.questions[0].multiSelect == true && q2?.questions[0].options[1].label == "Build output" && q2?.questions[0].options[1].recommended == true,
              "question: multiSelect, （建議） suffix")
        check(q2?.state == .answered(["Old caches, Build output（建議）", "Yes"]), "question: answers parsed from result text, quotes escaped (\(String(describing: q2?.state)))")
        check(q(3)?.state == .declined, "question: error result is .declined")
        check(q(5)?.state == .pending && q(5)?.toolUseId == "toolu_q4", "question: no result yet is .pending")
        check(!items.contains { if case .permissionRequest = $0.kind { return true }; return false }, "question: never a permissionRequest")
        check(items[5].id == "q-toolu_q4" && SessionLog.parse(lines: ql).map(\.id) == items.map(\.id), "question: stable ids")
    }
}

// Codex questions: request_user_input (picker) and request_user_input_async (answered by the next user message)
@MainActor func checksCodexQuestions() async throws {
    do {
        let cl = String(decoding: fixture("question-codex.jsonl"), as: UTF8.self).split(separator: "\n").map(String.init)
        let items = SessionLog.parse(lines: cl)
        check(describe(items) == ["user:Ask me things.", "q:Color", "q:Size|Pet", "q:Go", "q:", "asst:Waiting for your pick.", "user:Safe", "q:Ship"],
              "codex question: items \(describe(items))")
        func q(_ i: Int) -> QuestionRequest? { if case .question(let r) = items[i].kind { return r }; return nil }
        check(q(1)?.agent == "codex" && q(1)?.delivery == .picker && q(1)?.questions[0].id == "color"
              && q(1)?.questions[0].options.map(\.label) == ["Red", "Blue"] && q(1)?.questions[0].options[0].recommended == true,
              "codex question: picker, id, (Recommended) flagged")
        check(q(1)?.state == .answered(["Blue"]), "codex question: answer by id")
        check(q(2)?.state == .answered(["Large", "一隻魚 fish"]), "codex question: notes replace None of the above (\(String(describing: q(2)?.state)))")
        check(q(3)?.state == .declined, "codex question: unavailable output is .declined")
        check(q(4)?.delivery == .message && q(4)?.questions[0].text == "Which plan?" && q(4)?.questions[0].options.map(\.label) == ["Fast", "Safe"],
              "codex question: async title and string options")
        check(q(4)?.state == .answered(nil), "codex question: async answered by the next user message")
        check(q(7)?.state == .pending, "codex question: no output yet is .pending")
        check(!items.contains { if case .permissionRequest = $0.kind { return true }; if case .toolChips = $0.kind { return true }; return false },
              "codex question: no permission, no tool chip")
        var p = ConversationParser()
        for l in cl.prefix(10) { p.feed(line: l) }
        check(p.items().contains { if case .question(let r) = $0.kind { return r.delivery == .message && r.state == .pending }; return false },
              "codex question: async stays pending after {accepted:true}")
    }
}

// Claude Code question picker read from the screen (layout as captured from Claude Code 2.1.296)
@MainActor func checksQuestionScreen() async throws {
    do {
        let single = """
        ❯ Ask me.
        ────────────────────
         ☐ Color
        Pick a color?
        ❯ 1. Red (Recommended)
             warm
          2. Blue
             cool
          3. Type something.
        ────────────────────
          4. Chat about this
        Enter to select · ↑/↓ to navigate · Esc to cancel
        """
        let r = QuestionAdapter.claudeScreen(single)
        check(r?.headers == ["Color"] && r?.question.text == "Pick a color?" && r?.question.options.map(\.label) == ["Red", "Blue"]
              && r?.question.options.map(\.recommended) == [true, false] && r?.question.options.map(\.detail) == ["warm", "cool"] && r?.question.multiSelect == false,
              "screen question: single \(String(describing: r))")
        let multi = """
        ←  ☐ Size  ☒ Tops  ☐ Pay  ✔ Submit  →
        Which toppings would you like
        on top?
        ❯ 1. [✔] Cheese
             Melted
          2. [ ] Olive
          3. [ ] Type something
             Submit
        ────────────────────
          4. Chat about this
        """
        let m = QuestionAdapter.claudeScreen(multi)
        check(m?.headers == ["Size", "Tops", "Pay"] && m?.question.text == "Which toppings would you like on top?" && m?.question.multiSelect == true
              && m?.question.options.map(\.label) == ["Cheese", "Olive"], "screen question: multiSelect, wrapped text, tab bar \(String(describing: m))")
        check(QuestionAdapter.claudeScreen("⏺ User answered Claude's questions:\n  ⎿  · Pick a color? → Blue") == nil
              && QuestionAdapter.claudeScreen("Do you want to proceed?\n❯ 1. Yes\n  2. No") == nil, "screen question: none without a picker")
    }
}

// Question answer keys (verified in c9-input-test; docs/research/ask-user-question-keys.md)
@MainActor func checksQuestionKeys() async throws {
    do {
        typealias Q = QuestionRequest.Question
        let opts2 = [QuestionRequest.Option(label: "A"), .init(label: "B")]
        let single = QuestionRequest(toolUseId: "t", questions: [Q(header: "H", text: "Pick one?", options: opts2)])
        let multi = QuestionRequest(toolUseId: "t", questions: [Q(header: "H", text: "Pick some?", options: opts2, multiSelect: true)])
        let three = QuestionRequest(toolUseId: "t", questions: [Q(header: "1", text: "First?", options: opts2),
                                                                 Q(header: "2", text: "Second?", options: opts2, multiSelect: true),
                                                                 Q(header: "3", text: "Third?", options: opts2)])
        typealias A = QuestionAnswer
        check((try? QuestionAdapter.steps(for: single, answers: [A(picks: [1])])) == [.text("2")], "keys: claude single = digit")
        check((try? QuestionAdapter.steps(for: single, answers: [A(other: "a fish")])) == [.text("3"), .text("a fish"), .keys(["Enter"])], "keys: claude single Other")
        check((try? QuestionAdapter.steps(for: multi, answers: [A(picks: [1, 0], other: "tart")])) ==
              [.text("1"), .text("2"), .text("3"), .keys(["Down", "Down"]), .text("tart"), .keys(["Tab"]), .keys(["Enter"]), .waitFor("Review your answers"), .text("1")],
              "keys: claude multiSelect + Other")
        check((try? QuestionAdapter.steps(for: three, answers: [A(picks: [0]), A(picks: [1]), A(other: "x")])) ==
              [.text("1"), .waitFor("Second?"), .text("2"), .keys(["Tab"]), .waitFor("Third?"), .text("3"), .text("x"), .keys(["Enter"]), .waitFor("Review your answers"), .text("1")],
              "keys: claude three questions")
        var cx = three; cx.agent = "codex"; cx.questions[1].multiSelect = false
        check((try? QuestionAdapter.steps(for: cx, answers: [A(picks: [0]), A(picks: [1]), A(other: "一隻魚")])) ==
              [.text("1"), .waitFor("Second?"), .text("2"), .waitFor("Third?"), .keys(["Down", "Down", "Tab"]), .text("一隻魚"), .keys(["Enter"])],
              "keys: codex digits, notes on None of the above")
        var cxm = multi; cxm.agent = "codex"
        func fails(_ q: QuestionRequest, _ a: [A]) -> Bool { (try? QuestionAdapter.steps(for: q, answers: a)) == nil }
        check(fails(cxm, [A(picks: [0])]) && fails(single, [A(picks: [0, 1])]) && fails(single, [A()]) && fails(single, [A(picks: [5])])
              && fails(single, []) && fails(single, [A(other: "two\nlines")]), "keys: unsupported answers throw before sending")
        let screen = "←  ☐ H  ✔ Submit  →\nPick one?\n❯ 1. A\n  2. B\n  3. Type something.\n  4. Chat about this\nEnter to select"
        let echoed = "❯ Ask: question 'Pick some?' and 'Pick one?'\n" + screen   // the prompt above repeats both questions
        check(!QuestionAdapter.screenShows(multi, screen: echoed) && QuestionAdapter.pickerRegion(agent: "claude", screen: echoed)?.contains("Pick some?") == false,
              "keys: only the picker region counts, not the echoed prompt")
        let cxScreen = "› Ask 'Cat or dog?' then 'Which size?'\n  Question 2/2 (1 unanswered)\n  Which size?\n  › 1. S\n  tab to add notes | enter to submit all"
        check(QuestionAdapter.pickerRegion(agent: "codex", screen: cxScreen)?.contains("Cat or dog?") == false
              && QuestionAdapter.pickerRegion(agent: "codex", screen: cxScreen)?.contains("Which size?") == true
              && QuestionAdapter.pickerRegion(agent: "codex", screen: "• Questions 1/1 answered\n  • Cat or dog?") == nil, "keys: codex picker region")
        check(QuestionAdapter.screenShows(single, screen: screen) && !QuestionAdapter.screenShows(multi, screen: screen)
              && !QuestionAdapter.screenShows(single, screen: "⏺ User answered Claude's questions:\n  ⎿  · Pick one? → B"), "keys: screen check needs picker and question")
        var asy = single; asy.agent = "codex"; asy.delivery = .message
        check(QuestionAdapter.messageText(for: asy, answers: [A(picks: [1])]) == "B" && QuestionAdapter.messageText(for: three, answers: [A(picks: [0]), A(picks: [0, 1]), A(other: "x")])
              == "First? A\nSecond? A, B\nThird? x", "keys: async message text")
    }
}
