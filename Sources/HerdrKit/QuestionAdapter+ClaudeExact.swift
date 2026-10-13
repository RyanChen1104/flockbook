import Foundation

// Claude Code 2.1.296's picker for a request the hub knows from the AskUserQuestion hook (`ClaudeQuestionHook`).
// Like `codexExact`: the screen must be the request's own rendering, compared with all whitespace dropped (wrapping
// does not count). Only the focus mark, the [✔] boxes, the tab-bar boxes and the hub's own Other text may vary,
// each at a known place. Anything else (a new Claude Code version, the user's own text) refuses: no key.
extension QuestionAdapter {
    /// Claude Code 2.1.296's key lines under a question (spacing aside), as captured live.
    static let claudeKeyLines: Set<String> = [
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
        "Enter to select · ↑/↓ to navigate · ctrl+g to edit in Vim · Esc to cancel",
        "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
        "Enter to select · Tab/Arrow keys to navigate · ctrl+g to edit in Vim · Esc to cancel",
    ]

    static func bare(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    /// The tab bar of `q`, whitespace dropped: one question, single choice: "☐Header"; else "←☐A☐B✔Submit→". A
    /// question's box is ☐ or ☒ (answered or not: Claude's own state, no key depends on it).
    static func claudeBar(_ q: QuestionRequest, _ line: String) -> Bool {
        var s = Substring(bare(line))
        func take(_ lit: String) -> Bool { guard s.hasPrefix(lit) else { return false }; s = s.dropFirst(lit.count); return true }
        let tabs = q.questions.count > 1 || q.questions.first?.multiSelect == true
        if tabs { guard take("←") else { return false } }
        for k in q.questions {
            guard take("☐") || take("☒"), take(bare(k.header)) else { return false }
        }
        if tabs { guard take("✔Submit→") else { return false } }
        return s.isEmpty
    }

    /// The label as Claude shows it: the log's label, with its "(Recommended)" when it had one.
    static func shownLabels(_ o: QuestionRequest.Option) -> [String] {
        o.recommended ? recommendedSuffixes.map { bare(o.label + $0) } : [bare(o.label)]
    }

    /// The picker on screen is question `k` of the hooked request `q`, exactly. From the bottom: the key line (the
    /// last line), "n+2. Chat about this" alone after the separator line, then from the last tab-bar line: the bar,
    /// the question text, per row an optional focus mark "❯", "i.", the box (multiSelect), the label and the
    /// description, then the Other row ("Type something." / "Type something" while empty, else `other`: the text
    /// the hub typed) and, multiSelect, the Submit row. Exactly one focus mark, on a row or Submit; `focus` says
    /// which one it must be (`.auto`: from `other`, as in `shows`). `checks`: the [✔] rows (Other = index n), when given.
    static func claudeExact(_ q: QuestionRequest, question k: Int, screen: String, other: String?, focus: FieldFocus, checks: Set<Int>?) -> Bool {
        guard q.agent == "claude", !q.toolUseId.hasPrefix("screen-"), q.questions.indices.contains(k) else { return false }
        let want = q.questions[k], n = want.options.count
        let lines = screen.components(separatedBy: "\n")
        let blank: (String) -> Bool = { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let foot = lines.lastIndex(where: { !blank($0) }),
              claudeKeyLines.contains(lines[foot].split(whereSeparator: \.isWhitespace).joined(separator: " ")),
              let sep = lines[..<foot].lastIndex(where: { l in
                  let t = l.trimmingCharacters(in: .whitespaces); return t.count >= 3 && t.allSatisfy { $0 == "─" }
              }),
              bare(lines[(sep + 1)..<foot].joined()) == "\(n + 2).Chataboutthis",
              let head = lines[..<sep].lastIndex(where: { l in
                  let t = l.trimmingCharacters(in: .whitespaces); return t.hasPrefix("☐") || t.hasPrefix("☒") || t.hasPrefix("←")
              }),
              claudeBar(q, lines[head]) else { return false }
        var body = Substring(bare(lines[(head + 1)..<sep].joined(separator: "\n")))
        func take(_ lit: String) -> Bool {
            guard body.hasPrefix(lit) else { return false }
            body = body.dropFirst(lit.count); return true
        }
        guard take(bare(want.text)) else { return false }
        var marks: [Int] = [], checked: Set<Int> = []
        func box(_ i: Int) -> Bool {
            guard want.multiSelect else { return true }
            if take("[✔]") { checked.insert(i); return true }
            return take("[]")
        }
        for (i, o) in want.options.enumerated() {
            if take("❯") { marks.append(i) }   // a row starts with its number: a mark right before it is the focus
            guard take("\(i + 1)."), box(i) else { return false }
            let fits = shownLabels(o).filter { body.hasPrefix($0) }
            guard fits.count == 1, take(fits[0]), take(bare(o.detail)) else { return false }
        }
        if take("❯") { marks.append(n) }
        guard take("\(n + 1)."), box(n) else { return false }
        let empty = want.multiSelect ? "Typesomething" : "Typesomething."
        guard take(other.map { $0.isEmpty ? empty : bare($0) } ?? empty) else { return false }
        if want.multiSelect {
            if take("❯") { marks.append(n + 1) }
            guard take("Submit") else { return false }
        }
        guard body.isEmpty, marks.count == 1, let mark = marks.first else { return false }
        if let checks, want.multiSelect, checks != checked { return false }
        // `.auto` as in `shows`: no hub text -> not on the Other row; "" -> on it (multiSelect: anywhere, Down moves
        // it there); text -> on it.
        let at: FieldFocus = focus != .auto ? focus : other == nil ? .auto : (other == "" && want.multiSelect) ? .any : .other
        switch at {
        case .auto: return mark < n
        case .any: return true
        case .other: return mark == n
        case .submit: return mark == n + 1
        }
    }

    /// The answer as Claude's review shows it: the picked labels in row order, then the Other text, ", " between.
    static func reviewParts(_ question: QuestionRequest.Question, _ a: QuestionAnswer) -> [[String]] {
        a.picks.sorted().map { shownLabels(question.options[$0]) } + [otherText(a)].compactMap { $0 }.map { [bare($0)] }
    }

    /// Claude's review screen of the hooked request `q` with the hub's `answers`, exactly: the tab bar, "Review your
    /// answers", per question "● text" and "→ answer", "Ready to submit your answers?", then "1. Submit answers" and
    /// "2. Cancel" with one focus mark. The last key ("1") goes only here.
    static func claudeReviewExact(_ q: QuestionRequest, answers: [QuestionAnswer], screen: String) -> Bool {
        guard q.agent == "claude", !q.toolUseId.hasPrefix("screen-"), answers.count == q.questions.count,
              zip(q.questions, answers).allSatisfy({ k, a in a.picks.allSatisfy { k.options.indices.contains($0) } }) else { return false }
        let lines = screen.components(separatedBy: "\n")
        guard let title = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "Review your answers" }),
              let head = lines[..<title].lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              claudeBar(q, lines[head]) else { return false }
        var body = Substring(bare(lines[(title + 1)...].joined(separator: "\n")))
        func take(_ lit: String) -> Bool {
            guard body.hasPrefix(lit) else { return false }
            body = body.dropFirst(lit.count); return true
        }
        for (k, a) in zip(q.questions, answers) {
            guard take("●" + bare(k.text) + "→") else { return false }
            for (j, alts) in reviewParts(k, a).enumerated() {
                if j > 0 { guard take(",") else { return false } }
                let fits = alts.filter { body.hasPrefix($0) }
                guard fits.count == 1, take(fits[0]) else { return false }
            }
        }
        guard take("Readytosubmityouranswers?") else { return false }
        var marks = 0
        if take("❯") { marks += 1 }
        guard take("1.Submitanswers") else { return false }
        if take("❯") { marks += 1 }
        guard take("2.Cancel"), body.isEmpty, marks == 1 else { return false }
        return true
    }
}
