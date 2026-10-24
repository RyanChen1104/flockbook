import Foundation
@testable import HerdrKit

// Grok Build's ask_user_question: the call is in the log while its picker is open; the result comes with the answer.
@MainActor func checksGrokQuestion() async throws {
    func line(_ n: Int, _ update: String) -> String {
        #"{"timestamp":1792000100,"method":"session/update","params":{"sessionId":"s","update":"# + update + #","_meta":{"eventId":"s-q\#(n)","agentTimestampMs":\#(1_792_000_100_000 + n)}}}"#
    }
    let user = line(1, #"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Pick for me."}}"#)
    let ask = line(2, #"{"sessionUpdate":"tool_call","toolCallId":"call-q-0","title":"ask_user_question","rawInput":{"questions":[{"question":"Which color?","options":[{"label":"Red (Recommended)","description":"Warm."},{"label":"Blue","description":"Cool."}]},{"question":"Which size?","options":[{"label":"Small","description":"Little."},{"label":"Large","description":"Big."}]}]},"_meta":{"x.ai/tool":{"name":"ask_user_question","kind":"ask_user"}}}"#)
    let tagged = line(3, #"{"sessionUpdate":"tool_call_update","toolCallId":"call-q-0","kind":"other","rawInput":{"variant":"AskUserQuestion","questions":[]}}"#)
    func done(_ n: Int, _ status: String, _ rest: String) -> String {
        line(n, #"{"sessionUpdate":"tool_call_update","toolCallId":"call-q-0","status":""# + status + #"""# + rest + "}")
    }
    let answered = done(4, "completed", #","content":[{"type":"content","content":{"type":"text","text":"User has answered your questions: \"Which color?\"=\"Red\", \"Which size?\"=\"Other\" user notes: huge."}}],"rawOutput":{"type":"AskUserQuestion","UserAnswered":{"answers":[{"question":"Which color?","options":["Red","Blue"],"picked":["Red"]},{"question":"Which size?","options":["Small","Large"],"picked":[],"typed":"huge"}]}}"#)
    let textOnly = done(4, "completed", #","content":[{"type":"content","content":{"type":"text","text":"User has answered your questions: \"Which color?\"=\"Blue\", \"Which size?\"=\"Small\"."}}]"#)
    let failed = done(4, "failed", #","content":[{"type":"content","content":{"type":"text","text":"dismissed"}}]"#)
    let cancelled = line(5, #"{"sessionUpdate":"turn_completed","stop_reason":"cancelled"}"#)

    func question(_ items: [ConversationItem]) -> QuestionRequest? {
        items.lazy.compactMap { if case .question(let q) = $0.kind { q } else { nil } }.first
    }
    let open = SessionLog.parse(lines: [user, ask, tagged])
    let q = question(open)
    check(q?.agent == "grok" && q?.delivery == .picker && q?.state == .pending && q?.toolUseId == "call-q-0"
          && open.last?.id == "q-call-q-0", "grok question: a pending picker card, last item \(describe(open))")
    check(q?.questions.map(\.text) == ["Which color?", "Which size?"] && q?.questions[0].options.map(\.label) == ["Red", "Blue"]
          && q?.questions[0].options[0].recommended == true && q?.questions[0].options[0].detail == "Warm."
          && q?.questions.allSatisfy { !$0.multiSelect } == true, "grok question: questions, labels, (Recommended)")
    check(chipCalls(open).isEmpty, "grok question: no tool chip for the question")
    check(question(SessionLog.parse(lines: [user, ask, tagged, answered]))?.state == .answered(["Red", "huge"]), "grok question: picked and typed answers")
    check(question(SessionLog.parse(lines: [user, ask, textOnly]))?.state == .answered(["Blue", "Small"]), "grok question: answers from the result text")
    check(question(SessionLog.parse(lines: [user, ask, failed]))?.state == .declined, "grok question: a failed call is declined")
    check(question(SessionLog.parse(lines: [user, ask, cancelled]))?.state == .declined, "grok question: a cancelled turn declines it")
    let multi = SessionLog.parse(lines: [line(2, #"{"sessionUpdate":"tool_call","toolCallId":"call-m","title":"ask_user_question","rawInput":{"questions":[{"question":"Which fruits?","options":[{"label":"Apple"},{"label":"Pear"}],"multi_select":true}]},"_meta":{"x.ai/tool":{"name":"ask_user_question","kind":"ask_user"}}}"#)])
    check(question(multi)?.questions.first?.multiSelect == true, "grok question: multi_select")

    // The hub: a blocked grok pane whose log ends with the pending question.
    let agent = Agent(name: "g", kind: "grok", status: .blocked, sessionId: nil, title: "")
    check(Hub.openQuestion(agent: agent, screen: "", items: open)?.toolUseId == "call-q-0", "grok question: the hub's open question")

    // The picker on screen (Grok Build 1.0.67, the shape captured live; text synthetic).
    func screen(_ text: String, _ rows: [(String, String)], at k: Int, of n: Int, mark: String = "○", above: String = "") -> String {
        let pad = String(repeating: " ", count: 60)
        var l = ["  ❯ Pick for me. \(above)", "", "  ◆ Ask \(n) questions", "", "  ┃", "  ┃  \(text)", "  ┃", "  ┃"]
        for (i, r) in rows.enumerated() { l.append("  ┃  \(i + 1) (\(mark)) \(r.0)  \(r.1)\(pad)█") }
        l += ["  ┃  z (○) Type your answer here", "  ┃", "  ┃  [\(k)/\(n)] ↑/↓ navigate · ←/→ question · y copy\(pad)\(k == n ? "Enter:submit" : "Enter:select")",
              "  ┃", "", "  Tab:next answer  │  Esc:scrollback  │  Shift+x:dismiss"]
        return l.joined(separator: "\n")
    }
    let color = [("Red", "Warm."), ("Blue", "Cool.")], size = [("Small", "Little."), ("Large", "Big.")]
    let s1 = screen("Which color?", color, at: 1, of: 2), s2 = screen("Which size?", size, at: 2, of: 2)
    if let q {
        check(QuestionAdapter.pickerRegion(agent: "grok", screen: s1) != nil && QuestionAdapter.screenShows(q, screen: s1), "grok picker: on screen")
        check(QuestionAdapter.shows(q, question: 0, screen: s1) && !QuestionAdapter.shows(q, question: 1, screen: s1)
              && QuestionAdapter.shows(q, question: 1, screen: s2) && !QuestionAdapter.shows(q, question: 0, screen: s2), "grok picker: the question shown, exactly")
        check(!QuestionAdapter.shows(q, question: 0, screen: screen("Which color?", color, at: 1, of: 3))
              && !QuestionAdapter.shows(q, question: 0, screen: screen("Which color?", [("Red", "Warm."), ("Green", "Cool.")], at: 1, of: 2))
              && !QuestionAdapter.shows(q, question: 0, screen: screen("Which color?", [("Red", "Warm.")], at: 1, of: 2))
              && !QuestionAdapter.shows(q, question: 0, screen: screen("Which color?", [("Red", "Hot."), ("Blue", "Cool.")], at: 1, of: 2))
              && !QuestionAdapter.shows(q, question: 0, screen: screen("Which colour?", color, at: 1, of: 2)), "grok picker: another count, option, detail or text: no match")
        check(!QuestionAdapter.shows(q, question: 0, screen: screen("Which color?", color, at: 1, of: 2, mark: "●")), "grok picker: a row already picked: no key")
        let noPicker = "  ❯ Which color? Red or Blue\n\n  ◆ Thinking\n\n  Shift+Tab:mode  │  Ctrl+.:shortcuts"
        check(QuestionAdapter.pickerRegion(agent: "grok", screen: noPicker) == nil && !QuestionAdapter.screenShows(q, screen: noPicker), "grok picker: the prompt repeating the question is not a picker")
        check(Hub.screenTakesKeys(s1), "grok picker: typed text would answer it")
        check((try? QuestionAdapter.steps(for: q, answers: [QuestionAnswer(picks: [0]), QuestionAnswer(picks: [1])]))
              == [.text("1"), .waitFor("Which size?"), .text("2")], "grok picker: a digit per question; the last one submits")
        check((try? QuestionAdapter.steps(for: q, answers: [QuestionAnswer(picks: [0]), QuestionAnswer(picks: [], other: "huge")])) == nil, "grok picker: free text is not sent")
    }
    if let m = question(multi) {
        check((try? QuestionAdapter.steps(for: m, answers: [QuestionAnswer(picks: [0])])) == nil, "grok picker: multi_select is not sent")
    }

    // Claude Code's hooks also run in Grok Build; its stdin is not Claude's, so the question hook never records it.
    let grokHook = #"{"hook_event_name":"PreToolUse","sessionId":"s","toolName":"ask_user_question","toolCallId":"call-q-0","toolInput":{"questions":[{"question":"Which color?","options":[{"label":"Red"}]}]}}"#
    check(ClaudeQuestionHook.record(Data(grokHook.utf8), time: Date()) == nil, "grok hook: a Grok PreToolUse payload is not a Claude question record")
}
