import Foundation

/// Everything that differs per agent for question cards: (a) parsing the tool call and its result,
/// (b) the screen markers and key sequence that answer it. Verified key sequences: docs/research/ask-user-question-keys.md.
public enum QuestionAdapter {

    // MARK: (a) Parse — Claude Code AskUserQuestion

    static let recommendedSuffixes = ["(Recommended)", "（Recommended）", "（建議）", "(建議)", "（推薦）", "(推薦)"]

    static func stripRecommended(_ raw: String) -> (String, Bool) {
        let label = raw.trimmingCharacters(in: .whitespaces)
        for suf in recommendedSuffixes where label.hasSuffix(suf) {
            return (String(label.dropLast(suf.count)).trimmingCharacters(in: .whitespaces), true)
        }
        return (label, false)
    }

    static func claude(id: String, input: [String: Any]) -> QuestionRequest? {
        guard let qs = input["questions"] as? [[String: Any]], !qs.isEmpty else { return nil }
        let questions = qs.map { q -> QuestionRequest.Question in
            let opts = (q["options"] as? [[String: Any]] ?? []).map { o -> QuestionRequest.Option in
                let (label, rec) = stripRecommended(o["label"] as? String ?? "")
                return .init(label: label, detail: o["description"] as? String ?? "", recommended: rec)
            }
            return .init(header: q["header"] as? String ?? "", text: q["question"] as? String ?? "",
                         options: opts, multiSelect: q["multiSelect"] as? Bool ?? false)
        }
        return QuestionRequest(toolUseId: id, agent: "claude", questions: questions)
    }

    /// Answers come from the line's `toolUseResult.answers` (question text -> answer), else from the result text
    /// (`"question"="answer", …`). An error result is a rejection.
    static func claudeState(_ q: QuestionRequest, isError: Bool, result: Any?, text: String) -> QuestionRequest.State {
        if isError { return .declined }
        var byQuestion: [String: String] = [:]
        if let r = result as? [String: Any], let a = r["answers"] as? [String: String] { byQuestion = a }
        else {
            for m in text.matches(of: /"((?:[^"\\]|\\.)*)"="((?:[^"\\]|\\.)*)"/) {
                func un(_ s: Substring) -> String { s.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\") }
                byQuestion[un(m.1)] = un(m.2)
            }
        }
        return answered(q.questions.map { byQuestion[$0.id] })
    }

    // MARK: (a) Parse — Codex request_user_input / request_user_input_async

    static let codexTools: Set<String> = ["request_user_input", "request_user_input_async"]

    /// `request_user_input` (Plan mode picker): `{questions:[{id, header, question, options:[{label, description}]}]}`.
    /// `request_user_input_async`: `{questions:[{title, options:[String]}]}`; it returns at once, the user answers in a message.
    static func codex(name: String, callId: String, arguments: String) -> QuestionRequest? {
        guard codexTools.contains(name), let d = arguments.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let qs = o["questions"] as? [[String: Any]], !qs.isEmpty else { return nil }
        let questions = qs.enumerated().map { k, q -> QuestionRequest.Question in
            let opts: [QuestionRequest.Option] = (q["options"] as? [Any] ?? []).compactMap { o in
                if let s = o as? String { let (l, r) = stripRecommended(s); return .init(label: l, recommended: r) }
                guard let o = o as? [String: Any] else { return nil }
                let (l, r) = stripRecommended(o["label"] as? String ?? "")
                return .init(label: l, detail: o["description"] as? String ?? "", recommended: r)
            }
            let text = q["question"] as? String ?? q["title"] as? String ?? ""
            return .init(id: q["id"] as? String ?? "q\(k)", header: q["header"] as? String ?? "", text: text,
                         options: opts, multiSelect: q["multiSelect"] as? Bool ?? q["multi_select"] as? Bool ?? false)
        }
        return QuestionRequest(toolUseId: callId, agent: "codex",
                               delivery: name == "request_user_input" ? .picker : .message, questions: questions)
    }

    /// Codex picker output: `{"answers":{"<id>":{"answers":["Blue"]}}}`; the notes come as `"user_note: …"`.
    /// Anything else (e.g. "unavailable in Default mode", an interrupt) means no answer. The async tool's
    /// `{"accepted":true}` returns nil: the question stays pending until the next user message.
    static func codexState(_ q: QuestionRequest, output: String) -> QuestionRequest.State? {
        let o = output.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if q.delivery == .message, o?["accepted"] as? Bool == true { return nil }
        guard let byId = o?["answers"] as? [String: Any] else { return .declined }
        return answered(q.questions.map { question -> String? in
            guard let list = (byId[question.id] as? [String: Any])?["answers"] as? [String] else { return nil }
            let notes = list.filter { $0.hasPrefix("user_note: ") }.map { String($0.dropFirst(11)) }
            var picks = list.filter { !$0.hasPrefix("user_note: ") }
            if !notes.isEmpty { picks.removeAll { $0 == codexOtherLabel } }
            return (picks + notes).joined(separator: ", ")
        })
    }

    static func answered(_ answers: [String?]) -> QuestionRequest.State {
        guard answers.contains(where: { $0 != nil }) else { return .answered(nil) }
        return .answered(answers.map { $0 ?? "" })
    }

    // MARK: (b) Answer — screen markers and keys

    /// Codex's own last picker row; picking it with notes is how free text is given.
    static let codexOtherLabel = "None of the above"

    /// Text that is on screen only while the agent's question picker is open.
    public static func markers(agent: String) -> [String] {
        agent == "codex" ? ["enter to submit"] : ["Chat about this", "Review your answers"]
    }

    /// One step of an answer. `waitFor` blocks until the picker (not the rest of the screen) shows the text.
    public enum Step: Sendable, Hashable {
        case text(String)
        case keys([String])
        case waitFor(String)
    }

    public enum Failure: Error, Sendable, Hashable, CustomStringConvertible {
        /// The pane does not show this question's picker: nothing was sent.
        case notOnScreen
        /// This answer cannot be given with keys (e.g. multiSelect on Codex). Nothing was sent.
        case unsupported(String)
        /// Keys were sent, but the expected screen did not come (stopped there).
        case stuck(String)
        /// All keys were sent, but the picker is still on screen.
        case stillOnScreen
        public var description: String {
            switch self {
            case .notOnScreen: "the question is not on screen"
            case .unsupported(let m): "cannot answer: \(m)"
            case .stuck(let m): "stopped waiting for: \(m)"
            case .stillOnScreen: "the question is still on screen after answering"
            }
        }
    }

    /// Screen text with lines trimmed and joined, so a wrapped question still matches.
    static func flat(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            .replacing(/\s+/, with: " ")
    }

    /// Start of a question's text (short, so a wrap inside CJK text does not break the match).
    static func needle(_ q: QuestionRequest.Question) -> String {
        String(flat(q.text).prefix(24)).trimmingCharacters(in: .whitespaces)
    }

    /// The picker part of the screen only, flattened: Claude from its tab bar down, Codex from its "Question k/n" line
    /// down. Text above it (the user's own prompt often repeats the question) must not count. Nil = no picker.
    public static func pickerRegion(agent: String, screen: String) -> String? {
        let lines = screen.components(separatedBy: "\n")
        let start: Int?
        if agent == "codex" {
            start = lines.lastIndex { $0.firstMatch(of: /^\s*Question \d+\/\d+/) != nil }
        } else {
            start = lines.lastIndex { l in
                let t = l.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("☐") || t.hasPrefix("☒") || t.hasPrefix("✔") || t.hasPrefix("←")
            }
        }
        guard let start else { return nil }
        let region = flat(lines[start...].joined(separator: "\n"))
        return markers(agent: agent).contains { region.contains($0) } ? region : nil
    }

    /// The picker shows question `k` of `q` exactly: its text, its options in order and no other, the same mode
    /// (multiSelect), and for Claude the request's headers in the tab bar. `other`: what the hub put into the free
    /// text field so far: nil = nothing (Claude's "Other" row empty, Codex notes closed), "" = Codex notes opened
    /// and empty, else the text typed. Any other state (the user's own text, notes left open) is no match: a digit
    /// would be typed into that field. Codex: its rows are the options in order, then its own "None of the above".
    /// Where Claude's focus must be for the next key (`shows`). `.auto`: from `other` (nil: off the Other row;
    /// "": on it, anywhere for multiSelect; text: on it).
    public enum FieldFocus: Sendable { case auto, any, other, submit }

    public static func shows(_ q: QuestionRequest, question k: Int, screen: String, other: String? = nil, focus: FieldFocus = .auto) -> Bool {
        guard q.questions.indices.contains(k) else { return false }
        let want = q.questions[k], labels = want.options.map { flat($0.label) }
        if q.agent == "codex" {
            guard !want.multiSelect, let s = codexScreen(screen), s.text == flat(want.text), s.rows.count == labels.count + 1,
                  s.rows.last?.hasPrefix(codexOtherLabel) == true, s.notes == other.map(flat) else { return false }
            // A row: the label (maybe marked "(Recommended)"), then its description after two spaces.
            return zip(s.rows, want.options).allSatisfy { row, o in
                let (label, rec) = stripRecommended(row.components(separatedBy: "  ").first ?? row)
                return flat(label) == flat(o.label) && rec == o.recommended
            }
        }
        guard let s = claudeParse(screen), q.headers.isEmpty || s.headers == q.headers,
              flat(s.question.text) == flat(want.text), s.question.multiSelect == want.multiSelect,
              s.question.options.map({ flat($0.label) }) == labels else { return false }
        // The "Other" row with focus is a text field: a digit there is typed, not a pick. Its empty look ("Type
        // something.") may be the user's own text, so a pick needs the row without focus and empty; "" (opened by
        // the hub's digit, live: focus on it) needs it empty (multiSelect: Down moves focus there); text, ours.
        let field: Bool
        switch other.map(flat) {
        case nil: field = s.typed == nil
        case ""?: field = s.typed == nil
        case let t?: field = s.typed.map(flat) == t
        }
        let where_: FieldFocus = focus != .auto ? focus : other == nil ? .auto : (other == "" && want.multiSelect) ? .any : .other
        switch where_ {
        case .auto: return field && !s.otherFocused
        case .any: return field
        case .other: return field && s.otherFocused
        case .submit: return field && s.submitFocused
        }
    }

    /// Codex's picker, read from the screen: the question text (flat) and its option rows in order, each row's
    /// text after "N." (label, then its description after two spaces), and `notes`: nil when closed, "" when open
    /// and empty ("› Add notes"), else their text (Codex 0.162, live). Nil when no Codex picker is shown or the
    /// rows are not numbered 1, 2, 3...
    static func codexScreen(_ screen: String) -> (text: String, rows: [String], notes: String?)? {
        let lines = screen.components(separatedBy: "\n")
        guard let start = lines.lastIndex(where: { $0.firstMatch(of: /^\s*Question \d+\/\d+/) != nil }),
              pickerRegion(agent: "codex", screen: screen) != nil else { return nil }
        let rowRe = /^\s*(?:›\s*)?(\d+)\.\s+(.*)$/
        // The key line is the last line of the picker, one of Codex's own two; text above it (notes too) may hold
        // the same words and never ends the parse.
        guard let foot = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), foot > start else { return nil }
        let keyLine = lines[foot].trimmingCharacters(in: .whitespaces)
        let notesOpen: Bool
        if keyLine.hasPrefix("tab or esc to clear notes | enter to submit") { notesOpen = true }
        else if keyLine.hasPrefix("tab to add notes | enter to submit") { notesOpen = false }
        else { return nil }
        var text: [String] = [], rows: [String] = [], notes: [String] = [], inNotes = false, after = false
        for l in lines[(start + 1)..<foot] {
            let t = l.trimmingCharacters(in: .whitespaces)
            if inNotes {
                if !t.isEmpty { notes.append(t) }
            } else if !after, let m = l.wholeMatch(of: rowRe) {
                guard Int(m.1) == rows.count + 1 else { return nil }
                rows.append(String(m.2).trimmingCharacters(in: .whitespaces))
            } else if rows.isEmpty {
                if !t.isEmpty { text.append(t) }
            } else if t.isEmpty {
                after = true
            } else if after, t.hasPrefix("›") {
                inNotes = true
                notes.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else {
                return nil   // a wrapped row or something unknown: cannot be compared exactly
            }
        }
        guard !rows.isEmpty, !text.isEmpty, inNotes == notesOpen else { return nil }   // the key line and the field agree
        let typed = flat(notes.joined(separator: "\n"))
        return (flat(text.joined(separator: " ")), rows, inNotes ? (typed == "Add notes" ? "" : typed) : nil)
    }

    /// Two questions are the same: text, option labels in order, mode.
    static func sameQuestion(_ a: QuestionRequest.Question, _ b: QuestionRequest.Question) -> Bool {
        flat(a.text) == flat(b.text) && a.options.map { flat($0.label) } == b.options.map { flat($0.label) } && a.multiSelect == b.multiSelect
    }

    /// `full` (every question read) is the request the client answered (`asked`, maybe with questions unread):
    /// the same agent, headers and question count, and every question `asked` holds is in `full`, unchanged.
    public static func sameRequest(_ full: QuestionRequest, as asked: QuestionRequest) -> Bool {
        guard full.agent == asked.agent, full.headers == asked.headers, full.unread == 0,
              asked.headers.isEmpty || full.questions.count == asked.headers.count else { return false }
        if asked.questions.count == full.questions.count { return zip(asked.questions, full.questions).allSatisfy { sameQuestion($0, $1) } }
        return asked.questions.allSatisfy { a in full.questions.contains { sameQuestion(a, $0) } }
    }

    /// The picker shows some question of `q` exactly (`shows`).
    public static func showsAny(_ q: QuestionRequest, screen: String) -> Bool {
        q.questions.indices.contains { shows(q, question: $0, screen: screen) }
    }

    /// Claude's review screen of `q`: the request's headers and every one of its questions listed.
    public static func showsReview(_ q: QuestionRequest, screen: String) -> Bool {
        guard let region = pickerRegion(agent: q.agent, screen: screen), region.contains("Review your answers") else { return false }
        return q.headers.allSatisfy { region.contains($0) } && q.questions.allSatisfy { region.contains(flat($0.text)) }
    }

    public static func pickerShown(_ q: QuestionRequest, screen: String) -> Bool {
        pickerRegion(agent: q.agent, screen: screen) != nil
    }

    /// The picker is open and shows the first question.
    public static func screenShows(_ q: QuestionRequest, screen: String) -> Bool {
        guard let first = q.questions.first, let region = pickerRegion(agent: q.agent, screen: screen) else { return false }
        return region.contains(needle(first))
    }

    /// The key sequence for a picker question. Throws `.unsupported` before anything is sent.
    public static func steps(for q: QuestionRequest, answers: [QuestionAnswer]) throws -> [Step] {
        guard answers.count == q.questions.count else { throw Failure.unsupported("\(answers.count) answers for \(q.questions.count) questions") }
        for (k, a) in answers.enumerated() {
            let n = q.questions[k].options.count
            guard a.picks.allSatisfy({ (0..<n).contains($0) }), n <= 8 else { throw Failure.unsupported("question \(k + 1): option out of range") }
            let other = a.other?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if other.contains(where: \.isNewline) { throw Failure.unsupported("question \(k + 1): line break in the text") }
            // The empty field shows these: the gate could not tell the answer from no answer.
            if ["Add notes", "Type something.", "Type something"].contains(flat(other)) { throw Failure.unsupported("question \(k + 1): this text is the field's placeholder") }
            if a.picks.isEmpty && other.isEmpty { throw Failure.unsupported("question \(k + 1): no answer") }
            if !q.questions[k].multiSelect && a.picks.count > 1 { throw Failure.unsupported("question \(k + 1): one choice only") }
        }
        return q.agent == "codex" ? try codexSteps(q, answers) : claudeSteps(q, answers)
    }

    static func otherText(_ a: QuestionAnswer) -> String? {
        let s = a.other?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    /// Claude Code 2.1.296. Single choice: digit picks and moves on ("Other" = digit n+1, text, Enter).
    /// multiSelect: digits toggle; "Other" = digit n+1, Down to the row, text, Tab, Enter; without it Tab moves on.
    /// After the last question of a multi-question or multiSelect card: review screen, `1` submits.
    static func claudeSteps(_ q: QuestionRequest, _ answers: [QuestionAnswer]) -> [Step] {
        var out: [Step] = []
        for (k, question) in q.questions.enumerated() {
            let a = answers[k], n = question.options.count
            if !question.multiSelect {
                if let other = otherText(a) { out += [.text("\(n + 1)"), .text(other), .keys(["Enter"])] }
                else { out.append(.text("\(a.picks[0] + 1)")) }
            } else {
                for p in a.picks.sorted() { out.append(.text("\(p + 1)")) }
                if let other = otherText(a) {
                    out += [.text("\(n + 1)"), .keys(Array(repeating: "Down", count: n)), .text(other), .keys(["Tab"]), .keys(["Enter"])]
                } else {
                    out.append(.keys(["Tab"]))
                }
            }
            if k + 1 < q.questions.count { out.append(.waitFor(needle(q.questions[k + 1]))) }
        }
        if q.questions.count > 1 || q.questions.last?.multiSelect == true {
            out += [.waitFor("Review your answers"), .text("1")]
        }
        return out
    }

    /// Codex 0.162 (Plan mode picker). Digit picks and moves on; on the last question it submits all.
    /// Free text: Down to "None of the above" (row n+1), Tab opens the notes, text, Enter. No multiSelect.
    static func codexSteps(_ q: QuestionRequest, _ answers: [QuestionAnswer]) throws -> [Step] {
        var out: [Step] = []
        for (k, question) in q.questions.enumerated() {
            if question.multiSelect { throw Failure.unsupported("Codex has no multiSelect picker") }
            let a = answers[k], n = question.options.count
            if let other = otherText(a) {
                out += [.keys(Array(repeating: "Down", count: a.picks.first ?? n) + ["Tab"]), .text(other), .keys(["Enter"])]
            } else {
                out.append(.text("\(a.picks[0] + 1)"))
            }
            if k + 1 < q.questions.count { out.append(.waitFor(needle(q.questions[k + 1]))) }
        }
        return out
    }

    /// `.message` delivery: the text sent as a user message. One question: the answer; several: "question: answer" lines.
    public static func messageText(for q: QuestionRequest, answers: [QuestionAnswer]) -> String {
        let parts = zip(q.questions, answers).map { question, a -> String in
            let v = (a.picks.sorted().map { question.options[$0].label } + [otherText(a)].compactMap { $0 }).joined(separator: ", ")
            return q.questions.count == 1 ? v : "\(question.text) \(v)"
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: Claude Code: the pending question comes from the screen

extension QuestionAdapter {
    /// A screen-read request. Headers go on the questions when all are read; the id depends only on the tab bar
    /// (plus the text for a single question), so the read-only and the full read give the same id.
    static func screenRequest(headers: [String], questions: [QuestionRequest.Question]) -> QuestionRequest {
        var qs = questions
        if qs.count == headers.count { for k in qs.indices { qs[k].header = headers[k] } }
        let key = headers.joined(separator: "|") + (headers.count == 1 ? "|" + (questions.first?.text ?? "") : "")
        let hash = key.utf8.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ UInt32($1) }   // stable across calls and runs
        return QuestionRequest(toolUseId: "screen-\(String(hash, radix: 16))", agent: "claude", questions: qs, headers: headers)
    }

    /// Claude Code 2.1.296 writes the AskUserQuestion call to its log only after it is answered, so while the
    /// picker is open the question exists only on screen. This reads the visible question: the tab-bar headers
    /// (one per question) and the current question with its options. Nil when no Claude picker is shown.
    public static func claudeScreen(_ screen: String) -> (headers: [String], question: QuestionRequest.Question)? {
        claudeParse(screen).map { ($0.headers, $0.question) }
    }

    /// `claudeScreen` plus `typed`: text typed into the "Other" row. 2.1.296 always shows that row as the last
    /// numbered row before the line above "Chat about this": "Type something." (multiSelect "Type something") when
    /// empty, else the typed text. It is never an option. No such line: nil (not a layout this reads).
    static func claudeParse(_ screen: String) -> (headers: [String], question: QuestionRequest.Question, typed: String?, otherFocused: Bool, submitFocused: Bool)? {
        let lines = screen.components(separatedBy: "\n")
        guard let end = lines.lastIndex(where: { $0.contains("Chat about this") }) else { return nil }
        let isBar: (String) -> Bool = { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("☐") || t.hasPrefix("☒") || t.hasPrefix("✔") || t.hasPrefix("←")
        }
        guard let bar = lines[..<end].lastIndex(where: isBar) else { return nil }
        let headers = lines[bar].split(whereSeparator: { "☐☒✔←→".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "Submit" }
        let optRe = /^\s*(?:❯\s*)?(\d+)\.\s+(\[[ ✔]\]\s+)?(.*)$/
        var text: [String] = [], options: [QuestionRequest.Option] = [], multi = false, inOptions = false, closed = false, lastRaw = "", lastFocused = false, submitFocused = false
        for l in lines[(bar + 1)..<end] {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("──") { closed = true; break }
            if t.hasPrefix("❯"), t.dropFirst().trimmingCharacters(in: .whitespaces) == "Submit" { submitFocused = true; continue }   // multiSelect
            if let m = l.wholeMatch(of: optRe) {
                let label = String(m.3).trimmingCharacters(in: .whitespaces)
                inOptions = true
                if m.2 != nil { multi = true }
                let (clean, rec) = stripRecommended(label)
                options.append(.init(label: clean, recommended: rec))
                lastRaw = label
                lastFocused = l.trimmingCharacters(in: .whitespaces).hasPrefix("❯")
            } else if inOptions {
                if !t.isEmpty, !options.isEmpty { options[options.count - 1].detail += (options[options.count - 1].detail.isEmpty ? "" : " ") + t }
            } else if !t.isEmpty {
                text.append(t)
            }
        }
        // The last row is the "Other" row.
        guard closed, options.popLast() != nil else { return nil }
        // The Other row keeps its raw text: "(Recommended)" there is typed text, not a mark.
        let typed: String? = lastRaw == "Type something." || lastRaw == "Type something" ? nil : lastRaw
        guard !options.isEmpty, !text.isEmpty else { return nil }
        let q = text.joined(separator: " ")
        return (headers, .init(header: headers.count == 1 ? headers[0] : "", text: q, options: options, multiSelect: multi), typed, lastFocused, submitFocused)
    }
}

extension HerdrClient {
    /// The pane's visible screen as plain text (read-only).
    public func visibleText(paneId: String) async throws -> String {
        let data = try await rawRequest(method: "pane.read", params: ["pane_id": paneId, "source": "visible", "format": "text", "lines": 60])
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let read = (o["result"] as? [String: Any])?["read"] as? [String: Any],
              let text = read["text"] as? String else { throw HerdrError.protocolError("pane.read has no text") }
        return text
    }

    /// Answers a pending question in `paneId`, one `QuestionAnswer` per question.
    /// Picker: (1) checks the picker with the first question is on screen (Claude: another question of this request
    /// is moved back with Left; anything else throws `.notOnScreen`, nothing sent),
    /// (2) sends the keys, waiting for each next question, (3) checks the picker is gone (else throws `.stillOnScreen`).
    /// Message (Codex async): sends the answer text and Enter, like the composer (`send(text:to:)`).
    public func answerQuestion(paneId: String, request q: QuestionRequest, answers: [QuestionAnswer], gate: KeyGate? = nil) async throws {
        guard q.state == .pending else { throw QuestionAdapter.Failure.unsupported("the question is not pending") }
        guard q.unread == 0 else { throw QuestionAdapter.Failure.unsupported("\(q.unread) questions not read yet (loadAllQuestions)") }
        if q.delivery == .message {
            guard answers.count == q.questions.count, answers.allSatisfy({ !$0.picks.isEmpty || QuestionAdapter.otherText($0) != nil })
            else { throw QuestionAdapter.Failure.unsupported("no answer") }
            try await gated(gate, paneId: paneId)
            try await send(text: QuestionAdapter.messageText(for: q, answers: answers), to: paneId)   // the composer path: text + Enter
            return
        }
        let steps = try QuestionAdapter.steps(for: q, answers: answers)
        // `gate` (a remote device): before every key, the same agent, the exact question the key is for on screen
        // (its text, options, the request's headers; the review screen for the last key), input allowed.
        let any: @Sendable (String) -> Bool = { QuestionAdapter.showsAny(q, screen: $0) }
        let screen = try await visibleText(paneId: paneId)
        if !QuestionAdapter.screenShows(q, screen: screen) {
            // Claude: the user may have moved the picker to a later question of THIS request; go back to question 1.
            guard q.agent == "claude", q.questions.count > 1, let shown = QuestionAdapter.claudeScreen(screen)?.question,
                  q.questions.dropFirst().contains(where: { $0.text == shown.text }) else { throw QuestionAdapter.Failure.notOnScreen }
            try await gatedKeys(Array(repeating: "Left", count: q.questions.count - 1), gate: gate, paneId: paneId, screen: any)
            guard try await waitScreen(paneId: paneId, timeout: 2, { QuestionAdapter.screenShows(q, screen: $0) }) else {
                throw QuestionAdapter.Failure.stuck("back to question 1")
            }
        }
        // `shown`: what the "Other" row of question `at` should hold now: empty until the hub typed its text there.
        // `focus`: Claude multiSelect "Other": Down keys may run with focus anywhere, the text and Tab need it on the
        // row, Enter needs it on Submit (live, 2.1.296).
        var at = 0, review = false, otherOpen = false, typedIn = false, shown: String?, focus = QuestionAdapter.FieldFocus.auto
        for step in steps {
            let k = at, r = review, inRow = shown, f = focus
            let same: @Sendable (String) -> Bool = { r ? QuestionAdapter.showsReview(q, screen: $0) : QuestionAdapter.shows(q, question: k, screen: $0, other: inRow, focus: f) }
            switch step {
            case .text(let s):
                try await gated(gate, paneId: paneId, screen: same)
                try await sendKeys(Array(s.utf8), to: paneId)   // typed as is: no Enter, not as a paste
                // By step purpose, not by text (the typed text may equal a digit): Claude's first text step for
                // "Other" is its digit, which opens the row; the next text step is the typed text.
                let typed = answers.indices.contains(k) ? QuestionAdapter.otherText(answers[k]) : nil
                if typed != nil, !otherOpen, q.agent == "claude", q.questions.indices.contains(k), s == "\(q.questions[k].options.count + 1)" { otherOpen = true; shown = "" }
                else if typed != nil, otherOpen, !typedIn { shown = typed; typedIn = true }
            case .keys(let k):
                try await gatedKeys(k, gate: gate, paneId: paneId, screen: same)
                let multiOther = q.agent == "claude" && otherOpen && q.questions.indices.contains(at) && q.questions[at].multiSelect
                if multiOther, !typedIn, k.allSatisfy({ $0 == "Down" }) { focus = .other }   // now on the row
                if multiOther, typedIn, k == ["Tab"] { focus = .submit }
                // Codex: Tab on "None of the above" opens its notes, empty.
                if q.agent == "codex", k.last == "Tab", answers.indices.contains(at), QuestionAdapter.otherText(answers[at]) != nil { otherOpen = true; shown = "" }
            case .waitFor(let s):
                if s == "Review your answers" { review = true } else { at += 1 }
                otherOpen = false; typedIn = false; shown = nil; focus = .auto
                guard try await waitScreen(paneId: paneId, timeout: 3, { QuestionAdapter.pickerRegion(agent: q.agent, screen: $0)?.contains(s) == true }) else {
                    throw QuestionAdapter.Failure.stuck(s)
                }
            }
            try await Task.sleep(for: .milliseconds(120))   // the TUI handles one key event per render
        }
        guard try await waitScreen(paneId: paneId, timeout: 5, { !QuestionAdapter.pickerShown(q, screen: $0) }) else {
            throw QuestionAdapter.Failure.stillOnScreen
        }
    }

    /// Claude Code's open question picker, read from the screen (its log has the call only after the answer).
    /// READ-ONLY: sends nothing, so it is safe to call automatically. `questions` = the question on screen;
    /// `headers` = all questions' headers from the tab bar; `unread` > 0 when there are more questions than the one
    /// shown (then call `loadAllQuestions` on a user action). Nil when the pane shows no Claude picker.
    /// `toolUseId` is "screen-…", the same for both calls (the real id appears in the log with the answer).
    public func pendingQuestion(paneId: String) async throws -> QuestionRequest? {
        guard let shown = QuestionAdapter.claudeScreen(try await visibleText(paneId: paneId)) else { return nil }
        return QuestionAdapter.screenRequest(headers: shown.headers, questions: [shown.question])
    }

    /// SENDS KEYS: call only on a user action (e.g. Next on question 1, or as the first step of Send), never on a
    /// timer, refresh or render. Moves the picker with Left to question 1, reads each question with Right
    /// (navigation only, nothing is chosen), then moves back to the question that was on screen and checks it is
    /// there again (`.stuck` if not). One question: no keys, same as `pendingQuestion`.
    public func loadAllQuestions(paneId: String, gate: KeyGate? = nil, expect: QuestionRequest? = nil) async throws -> QuestionRequest? {
        guard let shown = QuestionAdapter.claudeScreen(try await visibleText(paneId: paneId)) else { return nil }
        // `expect`: the request the caller answers. The picker must still show it (same headers, a question it
        // holds), before any key and in the result; else `.notOnScreen`, nothing sent.
        if let expect, shown.headers != expect.headers || !expect.questions.contains(where: { QuestionAdapter.sameQuestion($0, shown.question) }) {
            throw QuestionAdapter.Failure.notOnScreen
        }
        let n = shown.headers.count
        guard n > 1 else {
            let one = QuestionAdapter.screenRequest(headers: shown.headers, questions: [shown.question])
            if let expect, !QuestionAdapter.sameRequest(one, as: expect) { throw QuestionAdapter.Failure.notOnScreen }
            return one
        }
        func now() async throws -> QuestionRequest.Question? { QuestionAdapter.claudeScreen(try await visibleText(paneId: paneId))?.question }
        // `gate` (a remote device): before every key, the same agent, this request's picker still open, input allowed.
        // Bound to what was read: the same headers and, before each key, the exact question now expected on screen.
        let headers = shown.headers
        func exact(_ want: QuestionRequest.Question) -> @Sendable (String) -> Bool {
            { s in
                guard let r = QuestionAdapter.claudeScreen(s), r.headers == headers else { return false }
                return QuestionAdapter.sameQuestion(r.question, want)
            }
        }
        // To question 1 (Left stops there). Navigation keys only; none of them chooses anything.
        try await gated(gate, paneId: paneId, screen: exact(shown.question))
        try await sendNamedKeys(Array(repeating: "Left", count: n - 1), to: paneId)
        try await Task.sleep(for: .milliseconds(200))
        guard let first = try await now() else { throw QuestionAdapter.Failure.stuck("question 1") }
        var questions = [first]
        for _ in 1..<n {
            try await gated(gate, paneId: paneId, screen: exact(questions[questions.count - 1]))
            try await sendNamedKeys(["Right"], to: paneId)
            var next: QuestionRequest.Question?
            _ = try await waitScreen(paneId: paneId, timeout: 2) { screen in
                guard let r = QuestionAdapter.claudeScreen(screen), r.question.text != questions.last?.text else { return false }
                next = r.question; return true
            }
            guard let q = next else { throw QuestionAdapter.Failure.stuck("reading question \(questions.count + 1)") }
            questions.append(q)
        }
        // Back to where the picker was.
        let back = n - 1 - (questions.firstIndex { $0.text == shown.question.text } ?? 0)
        if back > 0 {
            try await gated(gate, paneId: paneId, screen: exact(questions[questions.count - 1]))
            try await sendNamedKeys(Array(repeating: "Left", count: back), to: paneId)
        }
        guard try await waitScreen(paneId: paneId, timeout: 2, { QuestionAdapter.claudeScreen($0)?.question.text == shown.question.text }) else {
            throw QuestionAdapter.Failure.stuck("back to the question on screen")
        }
        let full = QuestionAdapter.screenRequest(headers: shown.headers, questions: questions)
        if let expect, !QuestionAdapter.sameRequest(full, as: expect) { throw QuestionAdapter.Failure.notOnScreen }
        return full
    }

    private func waitScreen(paneId: String, timeout: Double, _ ok: (String) -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while true {
            if ok(try await visibleText(paneId: paneId)) { return true }
            if Date() >= end { return false }
            try await Task.sleep(for: .milliseconds(150))
        }
    }
}
