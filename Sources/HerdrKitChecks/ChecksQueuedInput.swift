import Foundation
@testable import HerdrKit

// The agents' own queues (QueuedInput) and pulling them back (QueuePull). Screens are shaped like Claude Code 2.1 and
// Codex 0.163 draw them; the text is made up.

private let rule = String(repeating: "─", count: 60)

private func claudeScreen(queued: [String], above: String = "⏺ ALPHA", input: String = "❯ Press up to edit queued messages") -> String {
    ([above] + queued.map { "❯ " + $0 } + ["  ctrl+enter to send now", "· Pouncing… (10s · ↓ 864 tokens)", rule, input, rule,
     "  ⏵⏵ auto mode on (shift+tab to cycle)"]).joined(separator: "\n")
}

private func codexScreen(queued: [String], input: String = "› Ask Codex to do anything") -> String {
    (["› Run the shell command", "• Working (30s • esc to interrupt)", "• Queued follow-up inputs"] + queued.map { "  ↳ " + $0 }
     + ["    ⇧← edit last queued message", input, "  GPT-5.6-Luna max · max · Context 96% left", "  ← for agents · ? for shortcuts"]).joined(separator: "\n")
}

private func working(_ kind: String) -> Agent { Agent(name: kind, kind: kind, status: .working, sessionId: "s-\(kind)", title: "") }

/// A pane for QueuePull: screens and agents in the order the pull reads them (a nil screen: the read failed); every
/// key list it sends.
@MainActor private final class FakePane: QueuePull.IO {
    var screens: [String?]
    var agents: [Agent?]
    var sent: [[String]] = []
    var keysOn = true
    var cols: Int? = 64
    init(screens: [String?], agents: [Agent?]) { self.screens = screens; self.agents = agents }
    func agent() async -> Agent? { agents.count > 1 ? agents.removeFirst() : agents.first ?? nil }
    func screen() async -> String? { screens.count > 1 ? screens.removeFirst() : screens.first ?? nil }
    func keys(_ k: [String], expect: Agent) async -> Bool { sent.append(k); return keysOn }
    func settle() async {}
    func width() async -> Int? { cols }
}

/// Claude Code's input box holding `rows` (the first after "❯ ", the rest indented two).
private func claudeBox(_ rows: [String], above: String = "⏺ ALPHA\n· Pouncing… (12s)") -> String {
    above + "\n" + rule + "\n" + rows.enumerated().map { $0 == 0 ? "❯ " + $1 : "  " + $1 }.joined(separator: "\n") + "\n" + rule
}

/// Words wrapped as a TUI does at `width` columns (CJK: anywhere). Test input only.
private func wrap(_ text: String, width: Int) -> [String] {
    var rows: [String] = []
    for line in text.components(separatedBy: "\n") {
        var row = ""
        for word in line.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            let cand = row.isEmpty ? word : row + " " + word
            if cand.count <= width { row = cand; continue }
            if !row.isEmpty { rows.append(row) }
            var w = word
            while w.count > width { rows.append(String(w.prefix(width))); w = String(w.dropFirst(width)) }
            row = w
        }
        rows.append(row)
    }
    return rows
}

@MainActor func checksQueuedInput() async throws {
    // Claude Code: the screen.
    let two = claudeScreen(queued: ["QC reply GAMMA", "QD reply DELTA"])
    let s = QueuedInput.claudeScreen(two)
    check(s?.items == ["QC reply GAMMA", "QD reply DELTA"] && s?.inputEmpty == true, "queue: Claude rows above 'ctrl+enter to send now', oldest first (\(String(describing: s)))")
    check(QueuedInput.claudeScreen(claudeScreen(queued: ["QC"], input: "❯ half typed"))?.inputEmpty == false, "queue: Claude input with text is not empty")
    check(QueuedInput.claudeScreen("❯ hello\n⏺ Hi\n" + rule + "\n❯ \n" + rule) == nil, "queue: no hint line, no queue")

    // Claude Code: the log.
    var log = ClaudeQueueLog()
    for o: [String: Any] in [
        ["type": "queue-operation", "operation": "enqueue", "content": "QA"], ["type": "queue-operation", "operation": "enqueue", "content": "QB"],
        ["type": "queue-operation", "operation": "remove", "content": "QA"], ["type": "queue-operation", "operation": "enqueue", "content": "QC"],
        ["type": "queue-operation", "operation": "dequeue"], ["type": "queue-operation", "operation": "enqueue"],
    ] { log.feed(o) }
    check(log.items == ["QC", nil], "queue: log enqueue/remove/dequeue; an enqueue without content is a nil (\(log.items))")
    log.feed(["type": "queue-operation", "operation": "popAll", "content": "QC"]); log.feed(["type": "queue-operation", "operation": "popAll"])
    check(log.items.isEmpty, "queue: popAll empties it")
    let fixtureLog = String(decoding: fixture("queued.jsonl"), as: UTF8.self).split(separator: "\n").map(String.init)
    var parser = ConversationParser()
    for l in fixtureLog { parser.feed(line: l) }
    check(parser.queue.items.isEmpty, "queue: the fixture's queue ends empty (enqueue, remove, dequeue)")
    var open = ConversationParser()
    for l in fixtureLog.prefix(3) { open.feed(line: l) }
    check(open.queue.items == ["Also check the lint step."], "queue: the parser keeps the log's open queue")

    // Claude Code: log and screen together.
    let compact = claudeScreen(queued: ["/compact", "QH reply HOTEL"], above: "⏺ done")
    let filled = QueuedInput.read(agent: working("claude"), screen: compact, log: [nil])
    check(filled?.items == ["QH reply HOTEL"], "queue: compaction's enqueue has no text; the newest screen row fills it, the sent prompt above stays out (\(String(describing: filled?.items)))")
    check(QueuedInput.read(agent: working("claude"), screen: two, log: ["QC reply GAMMA", "QD reply DELTA"])?.items == ["QC reply GAMMA", "QD reply DELTA"], "queue: log and screen agree")
    // P2-7 / r2 P2-6: the log and the screen are lined up by their text, not by count. The screen may draw only the
    // newest rows (just after an enqueue, or the box is cut by the pane's height): the log's older entries stay, at
    // any age. Time alone is no proof that an entry is stale, so Flockbook shows more rather than less.
    check(QueuedInput.read(agent: working("claude"), screen: claudeScreen(queued: ["QD reply DELTA"]), log: ["QC reply GAMMA", "QD reply DELTA"])?.items == ["QC reply GAMMA", "QD reply DELTA"],
          "queue: r2 P2-6: the screen shows only the newest row (at any age): the log's older entry stays")
    check(QueuedInput.read(agent: working("claude"), screen: claudeScreen(queued: ["QE new text"]), log: ["QE old text"])?.items == ["QE new text"],
          "queue: as many entries but other text: the screen's text, not the log's")
    check(QueuedInput.read(agent: working("claude"), screen: claudeScreen(queued: ["QA reply ALPHA", "QZ from the screen"]), log: ["QA reply ALPHA", nil])?.items == ["QA reply ALPHA", "QZ from the screen"],
          "queue: a log entry without text takes its screen row's text")
    check(QueuedInput.read(agent: working("claude"), screen: two, log: [])?.items.count == 2, "queue: a log not caught up yet: the screen's rows")
    var idle = working("claude"); idle.status = .idle
    check(QueuedInput.read(agent: idle, screen: two, log: ["QC reply GAMMA"]) == nil, "queue: none unless the agent works")
    check(QueuedInput.read(agent: working("pi"), screen: two, log: []) == nil, "queue: other agents: none")

    // Codex: the screen only.
    let cx = QueuedInput.read(agent: working("codex"), screen: codexScreen(queued: ["QB reply BETA", "QD reply DELTA"]), log: [])
    check(cx?.items == ["QB reply BETA", "QD reply DELTA"] && cx?.pullable == true && cx?.pullsAll == false, "queue: Codex rows under 'Queued follow-up inputs' (\(String(describing: cx)))")
    check(QueuedInput.read(agent: working("codex"), screen: codexScreen(queued: ["QB"], input: "› typing here"), log: [])?.pullable == false, "queue: Codex input with text: not pullable")

    // Keys: only Up, Shift-Left and Ctrl-U, never Escape.
    check(!QueuePull.safe(["Escape"]) && !QueuePull.safe(["esc"]) && !QueuePull.safe(["escape"]) && !QueuePull.safe(["Up", "Escape"]) && !QueuePull.safe(["Enter"]) && !QueuePull.safe(["\u{1b}"]) && !QueuePull.safe([]),
          "pull: Escape, Enter and raw bytes are refused")
    check(QueuePull.pullKey(agent: "claude") == "Up" && QueuePull.pullKey(agent: "codex") == "shift+left" && QueuePull.pullKey(agent: "pi") == nil, "pull: Up for Claude, Shift-Left for Codex")
    check(QueuePull.interrupts("• Working (2s • esc to interrupt)") == 0 && QueuePull.interrupts("  ⎿  Interrupted · What should Claude do instead?") == 1,
          "pull: 'esc to interrupt' is not an interrupt notice")

    var allKeys: [[String]] = []
    /// The texts kept (`keep`) and how many key lists had gone out when each was kept.
    var kept: [(String, Int)] = []
    func pull(_ kind: String, _ screens: [String?], log: ClaudeQueueLog = [], agents: [Agent?]? = nil, keysOn: Bool = true,
              cols: Int? = 64, saves: Bool = true, expect: Agent? = nil) async -> (QueuePull.Outcome, [[String]]) {
        let io = FakePane(screens: screens, agents: agents ?? [expect ?? working(kind)])
        io.keysOn = keysOn
        io.cols = cols
        kept = []
        let r = await QueuePull.run(expect: expect ?? working(kind), log: log, io: io) { t in kept.append((t, io.sent.count)); return saves }
        allKeys += io.sent
        return (r, io.sent)
    }
    let empty = rule + "\n❯ \n" + rule
    let pulledIn = claudeBox(["QC reply GAMMA", "QD reply DELTA"])
    let oneRow = claudeBox(["QC reply GAMMA"])
    let qcBlank = claudeBox(["QC reply GAMMA", ""])   // Ctrl-U emptied the second row; the next one takes its line break
    let gammaDelta = "QC reply GAMMA\nQD reply DELTA"
    let gd: ClaudeQueueLog = ["QC reply GAMMA", "QD reply DELTA"]
    let u = ["ctrl+u"]

    // Claude Code: Up, then one Ctrl-U at a time; the box is read again before each and must be exactly what the keys
    // so far left (Ctrl-U empties the last row; on an emptied row it takes the line break).
    var (r, k) = await pull("claude", [two, pulledIn, pulledIn, qcBlank, oneRow, "· Pouncing… (13s)\n" + empty], log: gd)
    check(r == .pulled(gammaDelta) && k == [["Up"], u, u, u], "pull: Claude: Up, then one Ctrl-U per key list until the box is empty (\(r), \(k))")
    check(kept.map(\.0) == [gammaDelta] && kept.first?.1 == 1, "pull: the text is kept after Up, before the first Ctrl-U (\(kept))")
    // The screen showed fewer rows than Up brought back (seen live: one row drawn, two queued): the composer gets every
    // line that came back, never only the expected ones (the rest would be cleared and lost).
    let more = claudeBox(["QK reply KILO", "QL reply LIMA"])
    (r, k) = await pull("claude", [claudeScreen(queued: ["QL reply LIMA"]), more, more, claudeBox(["QK reply KILO", ""]), claudeBox(["QK reply KILO"]), empty], log: ["QK reply KILO", "QL reply LIMA"])
    check(r == .pulled("QK reply KILO\nQL reply LIMA"), "pull: more came back than the screen showed: all of it (\(r))")
    // r5 P2-1: the box shows the message on two rows (wrapped, or a line break): the rows are not the same characters
    // as the log's text, so nothing goes on (before r5 the rows were joined and matched without spaces).
    let wrapped = claudeBox(["QW one two three", "four five"])
    (r, k) = await pull("claude", [claudeScreen(queued: ["QW one two three four five"]), wrapped, wrapped, claudeBox(["QW one two three"]), empty],
                        log: ["QW one two three four five"])
    check(r.isFailed && r.text == nil && kept.isEmpty && k == [["Up"]], "pull: r5 P2-1: rows that are not the text character for character: failed, nothing cleared (\(r), \(k))")
    // A message the box cannot show on one row per line (56 columns here), or with trailing spaces, tabs or blank
    // lines the screen drops: refused before any key, the queue keeps it.
    let cjk = String(repeating: "請檢查資料庫連線", count: 5)
    let cjkRows = [String(cjk.prefix(28)), String(cjk.dropFirst(28))]
    (r, k) = await pull("claude", [claudeScreen(queued: [cjk]), claudeBox(cjkRows), claudeBox(cjkRows), claudeBox([cjkRows[0]]), empty], log: [cjk])
    check(r.isRefused && k.isEmpty, "pull: r5 P2-1: CJK wider than a row: refused before any key (\(r), \(k))")
    for text in ["fix\n\n", "fix ", "a\tb", "if x:\n  run()  "] {
        (r, k) = await pull("claude", [claudeScreen(queued: ["fix"]), claudeBox(["fix"]), claudeBox(["fix"]), empty], log: [text])
        check(r.isRefused && k.isEmpty, "pull: r5 P2-1: \(text.debugDescription) cannot be shown exactly: refused before any key (\(r), \(k))")
    }
    let code = "if ready:\n    run()"
    let codeBox = claudeBox(["if ready:", "    run()"])
    (r, k) = await pull("claude", [claudeScreen(queued: [code]), codeBox, codeBox, claudeBox(["if ready:", ""]), claudeBox(["if ready:"]), empty], log: [code])
    check(r == .pulled(code) && k.first == ["Up"], "pull: r5: lines that fit, indentation kept: the same characters, pulled (\(r), \(k))")
    // r4 P2-2: Up brought back something else than the log gives: not exact, so nothing is kept, nothing goes to the
    // composer, nothing is cleared (before r4 it went to the composer as it was).
    let odd = claudeBox(["QZ something else"])
    (r, k) = await pull("claude", [two, odd, odd], log: gd)
    check(r.isFailed && r.text == nil && kept.isEmpty && k == [["Up"]], "pull: r4 P2-2: other text came back: not kept, not given on, not cleared (\(r), \(k))")

    // r5 P2-1: exact is the same characters, nothing less: the log's "a b" and a box holding "ab" are not the same
    // text (before r5 both were compared without spaces and line breaks).
    let ab = claudeBox(["ab"])
    (r, k) = await pull("claude", [claudeScreen(queued: ["a b"]), ab, ab, empty], log: ["a b"])
    check(r.isFailed && r.text == nil && kept.isEmpty && k == [["Up"]], "pull: r5 P2-1: the box holds 'ab', the log 'a b': not exact, not kept, not cleared (\(r), \(k))")
    // r5 P2-2: the box cannot be read after Up: nothing shows the text is exact, so it goes nowhere.
    (r, k) = await pull("claude", [two, nil], log: gd)
    check(r.isFailed && r.text == nil && kept.isEmpty && k == [["Up"]], "pull: r5 P2-2: the box cannot be read after Up: failed, not kept, not given on, no Ctrl-U (\(r), \(k))")
    // r5 P2-3: the pane runs another agent by the time Up would go (it changed while the screen was read): no key.
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, oneRow, oneRow, empty], log: gd, agents: [working("claude"), working("codex")])
    check(r.isRefused && k.isEmpty, "pull: r5 P2-3: Codex in the pane when Up would go: refused, no key (\(r), \(k))")

    // r6 P2-1: the log as Claude Code writes it, read through the parser: "fix\n\n" keeps its blank lines, so the box
    // (which drops them) cannot show it exactly: refused before any key (before r6 the log lost them and "fix" went on).
    var fixLog = ConversationParser()
    fixLog.feed(line: #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-16T09:45:30.000Z","sessionId":"s-claude","content":"fix\n\n"}"#)
    check(fixLog.queue.items == ["fix\n\n"], "queue: r6 P2-1: the parser keeps the log's text as written (\(fixLog.queue.items))")
    let fixBox = claudeBox(["fix"])
    (r, k) = await pull("claude", [claudeScreen(queued: ["fix"]), fixBox, fixBox, empty], log: fixLog.queue)
    check(r.isRefused && k.isEmpty && kept.isEmpty, "pull: r6 P2-1: 'fix\\n\\n' from the real log: refused before any key (\(r), \(k))")
    // r6 P2-2: the box's rows count only as they are on screen: a no-break space or a trailing space in the box is
    // not the log's text (before r6 the rows were cleaned first, and Ctrl-U cleared what the owner had changed).
    for row in ["a\u{a0}b", "a b "] {
        let changed = claudeBox([row])
        (r, k) = await pull("claude", [claudeScreen(queued: ["a b"]), changed, changed, empty], log: ["a b"])
        check(r.isFailed && r.text == nil && kept.isEmpty && k == [["Up"]], "pull: r6 P2-2: the box holds \(row.debugDescription): not exact, nothing cleared (\(r), \(k))")
    }
    // r6 P2-4: only characters of a known width (printable ASCII, CJK and fullwidth): an emoji may take 1 or 2
    // columns, so it is refused before any key (before r6 U+1FAE0 counted as 1).
    let melt = "fix \u{1FAE0}"
    (r, k) = await pull("claude", [claudeScreen(queued: [melt]), claudeBox([melt]), claudeBox([melt]), empty], log: [melt])
    check(r.isRefused && k.isEmpty, "pull: r6 P2-4: an emoji: refused before any key (\(r), \(k))")
    // r6 P2-5: a line that looks like the box's rule, and more lines than the screen shows: refused before any key.
    let ruled = "alpha\n" + String(repeating: "─", count: 12) + "\nbeta"
    (r, k) = await pull("claude", [claudeScreen(queued: [ruled.replacingOccurrences(of: "\n", with: "\n  ")]), claudeBox(["alpha"]), empty], log: [ruled])
    check(r.isRefused && k.isEmpty, "pull: r6 P2-5: a line like the box's rule: refused before any key (\(r), \(k))")
    let tall = (1...40).map { "line \($0)" }.joined(separator: "\n")
    // The screen (9 rows) cuts the queued message with "…"; it lines up with the log, and 40 lines do not fit.
    (r, k) = await pull("claude", [claudeScreen(queued: ["line 1\n  line 2…"]), claudeBox(tall.components(separatedBy: "\n")), empty], log: [tall])
    check(r.isRefused && k.isEmpty, "pull: r6 P2-5: 40 lines on a screen of fewer rows: refused before any key (\(r), \(k))")

    // r7 P2-1: the clearing reads the box as drawn too: the owner changes a space to a no-break space, or adds a
    // trailing space, after the first read: stopped, no Ctrl-U (before r7 those rows were cleaned and still matched).
    let abBox = claudeBox(["a b"])
    for row in ["a\u{a0}b", "a b "] {
        (r, k) = await pull("claude", [claudeScreen(queued: ["a b"]), abBox, claudeBox([row]), claudeBox([row]), empty], log: ["a b"])
        check(r.isPartial && k == [["Up"]], "pull: r7 P2-1: the box became \(row.debugDescription) before the first Ctrl-U: stopped, no Ctrl-U (\(r), \(k))")
    }
    // r7 P2-2: exact compares Unicode scalars, not canonically equal strings: U+F900 in the log, U+8C48 in the box.
    (r, k) = await pull("claude", [claudeScreen(queued: ["\u{F900}"]), claudeBox(["\u{8C48}"]), claudeBox(["\u{8C48}"]), empty], log: ["\u{F900}"])
    check(r.isFailed && r.text == nil && kept.isEmpty && k == [["Up"]], "pull: r7 P2-2: U+F900 and U+8C48 are not the same characters: failed, not cleared (\(r), \(k))")
    // r7 P2-3: a combining mark (here on its own at a line's start) has no width of its own: refused before any key.
    // The screen merges a mark with the column before it, so the check is on the text itself.
    for marked in ["\u{3099}fix", "ok\n\u{302A}x"] {
        check(!QueuePull.shows(marked, screen: two), "pull: r7 P2-3: a combining mark in \(marked.debugDescription): not shown exactly, refused before any key")
    }
    check(QueuePull.shows("ok\n\u{8C48}x", screen: two), "pull: r7: the same text without the mark passes the check")

    // r8 P2: before the first Ctrl-U the box must be the text as drawn, blank rows too: two line breaks added after
    // the first read stop it (before r8 trailing blank rows were dropped and Ctrl-U cleared the new ones too).
    (r, k) = await pull("claude", [claudeScreen(queued: ["a"]), claudeBox(["a"]), claudeBox(["a", "", ""]), claudeBox(["a", "", ""]), empty], log: ["a"])
    check(r.isPartial && k == [["Up"]], "pull: r8 P2: two blank rows added before the first Ctrl-U: stopped, no Ctrl-U (\(r), \(k))")
    // r8: a read that still shows the box before the last Ctrl-U (not redrawn yet): no key, the next read decides.
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, pulledIn, qcBlank, oneRow, empty], log: gd)
    check(r == .pulled(gammaDelta) && k == [["Up"], u, u, u], "pull: r8: the screen not redrawn after a Ctrl-U: no extra key (\(r), \(k))")
    // r8 P3: the text's last row is the placeholder's words: that row is still text, not an empty box.
    let ph = QueuedInput.claudePlaceholder
    let phText = ph + "\nmore"
    (r, k) = await pull("claude", [claudeScreen(queued: [ph + "\n  more"]), claudeBox([ph, "more"]), claudeBox([ph, "more"]), claudeBox([ph, ""]),
                                   claudeBox([ph]), empty], log: [phText])
    check(r == .pulled(phText) && k == [["Up"], u, u, u], "pull: r8 P3: the placeholder's words left as text: one more Ctrl-U, then empty (\(r), \(k))")

    // P1-1: the owner types in the terminal while it is cleared: stop, no more keys, the text still goes to the composer.
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, claudeBox(["QC reply GAMMA", "QD reply DELTA and more"])], log: gd)
    check(r == .partial(gammaDelta, r.why ?? "") && k == [["Up"], u], "pull: the box changed between two Ctrl-U: stopped, the text kept (\(r), \(k))")
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, qcBlank, claudeBox(["QC reply GAMMA typed"])], log: gd)
    check(r.isPartial && r.text == gammaDelta && k == [["Up"], u, u], "pull: text typed into a row Ctrl-U left: stopped, no more keys (\(r), \(k))")
    // P1-1: another agent in the pane after Up: no Ctrl-U at all.
    var other = working("claude"); other.sessionId = "another"
    (r, k) = await pull("claude", [two, pulledIn, pulledIn], log: gd, agents: [working("claude"), working("claude"), other])
    check(r.isPartial && r.text == gammaDelta && k == [["Up"]], "pull: another agent after Up: no Ctrl-U, the text kept (\(r), \(k))")
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, oneRow], log: gd, agents: [working("claude"), working("claude"), working("claude"), working("claude"), other])
    check(r.isPartial && r.text == gammaDelta && k == [["Up"], u], "pull: another agent between two Ctrl-U: stopped (\(k))")
    // P1-2: a failed read during or after the clearing: the text still comes back.
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, nil], log: gd)
    check(r.text == gammaDelta && k == [["Up"], u], "pull: the box cannot be read after a Ctrl-U: the text still goes to the composer (\(r))")
    // The text could not be kept: no Ctrl-U (the box keeps it), and it still goes to the composer.
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, oneRow, oneRow, empty], log: gd, saves: false)
    check(r.isPartial && r.text == gammaDelta && k == [["Up"]], "pull: not kept: no Ctrl-U (\(r), \(k))")
    // Ctrl-U never clears it: stop after a bounded number of keys.
    (r, k) = await pull("claude", [two, pulledIn], log: gd)
    check(r.isPartial && r.text == gammaDelta && k.count <= 7 && k.dropFirst().allSatisfy { $0 == u }, "pull: the box never empties: stopped after a few Ctrl-U (\(k.count - 1))")

    // r4 P2-1: only Claude Code's log gives the queued text exactly. Codex shows its queue on screen only (trailing
    // blank lines and spaces are gone there, line breaks look like wrapping): every Codex pull is refused before any
    // key, the queue stays as it is, and the owner edits it in Codex's terminal.
    let cxQueued = codexScreen(queued: ["QB reply BETA", "QD reply DELTA"])
    let cxPulled = codexScreen(queued: ["QB reply BETA"], input: "› QD reply DELTA")
    (r, k) = await pull("codex", [cxQueued, cxPulled, cxPulled, codexScreen(queued: ["QB reply BETA"])])
    check(r.isRefused && k.isEmpty && (r.refusedWhy ?? "").contains("terminal"), "pull: r4 P2-1: Codex, one row: refused before any key, edit it in the terminal (\(r), \(k))")
    let fix = codexScreen(queued: ["fix"])   // queued as "fix\n\n": the screen shows "fix"
    (r, k) = await pull("codex", [fix, codexScreen(queued: [], input: "› fix"), codexScreen(queued: [], input: "› fix"), codexScreen(queued: [])])
    check(r.isRefused && k.isEmpty, "pull: r4 P2-1: Codex 'fix' with trailing blank lines: refused, nothing cleared (\(r), \(k))")
    let cxCode = codexScreen(queued: [], input: "› if ready:\n      run()")
    (r, k) = await pull("codex", [codexScreen(queued: ["if ready:\n        run()"]), cxCode, cxCode, codexScreen(queued: [])])
    check(r.isRefused && k.isEmpty, "pull: Codex: a queued message on more than one row: refused before any key (\(r), \(k))")
    // Claude Code without the log's text (no log, or other text): refused before any key, one row too.
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, oneRow, empty])
    check(r.isRefused && k.isEmpty, "pull: r3 P2-1: Claude rows the log does not give exactly: refused before any key (\(r), \(k))")
    (r, k) = await pull("claude", [claudeScreen(queued: ["QC reply GAMMA"]), oneRow, oneRow, empty])
    check(r.isRefused && k.isEmpty, "pull: r4 P2-1: one row without the log: refused before any key (\(r), \(k))")
    // The log gives one message and Up brought back two rows of other text: not exact, no guess.
    (r, k) = await pull("claude", [claudeScreen(queued: ["QD reply DELTA"]), pulledIn, pulledIn, oneRow, empty], log: ["QD reply DELTA"])
    check(r.isFailed && r.text == nil && k == [["Up"]] && kept.isEmpty, "pull: r3 P2-1: more rows came back than the log gives: no Ctrl-U, no guess (\(r), \(k))")

    // r2 P1-4: the pull is bound to the agent's session: without one (nil or empty) Flockbook cannot tell another agent
    // of the same kind from it, so it refuses before any key.
    for sid in [nil, ""] as [String?] {
        var anon = working("claude"); anon.sessionId = sid
        (r, k) = await pull("claude", [two, pulledIn, pulledIn, oneRow, oneRow, empty], log: gd, expect: anon)
        check(r.isRefused && k.isEmpty, "pull: r2 P1-4: an agent without a session id (\(String(describing: sid))): refused, no key (\(r), \(k))")
    }
    var lost = working("claude"); lost.sessionId = nil
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, oneRow, oneRow, empty], log: gd, agents: [working("claude"), working("claude"), lost])
    check(r.isPartial && k == [["Up"]], "pull: r2 P1-4: the session id gone after Up: no Ctrl-U (\(r), \(k))")
    (r, k) = await pull("claude", [claudeScreen(queued: ["QC"], input: "❯ half typed")])
    check(r.isRefused && k.isEmpty, "pull: input box not empty: refused, no key")
    var notWorking = working("claude"); notWorking.status = .done
    (r, k) = await pull("claude", [two], log: gd, agents: [notWorking])
    check(r.isRefused && k.isEmpty, "pull: the turn ended: refused, no key")
    (r, k) = await pull("claude", [two], log: gd, agents: [other])
    check(r.isRefused && k.isEmpty, "pull: another agent in the pane: refused, no key")
    (r, k) = await pull("claude", ["⏺ nothing queued\n" + empty])
    check(r.isRefused && k.isEmpty, "pull: no queue on screen: refused, no key")
    (r, k) = await pull("claude", [two], log: gd, keysOn: false)
    check(r.isRefused && k == [["Up"]], "pull: input went off: nothing went out, no more keys")
    (r, k) = await pull("claude", [two, two], log: gd)
    check(r.isFailed && k == [["Up"]], "pull: the text did not come back (still queued): failed, no Ctrl-U")
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, qcBlank, oneRow, "  ⎿  Interrupted · What should Claude do instead?\n" + empty], log: gd)
    check(r == .interrupted(gammaDelta), "pull: an interrupt notice after the keys: interrupted, the text kept (\(r))")
    var blocked = working("claude"); blocked.status = .blocked
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, qcBlank, oneRow, empty], log: gd, agents: Array(repeating: working("claude"), count: 9) + [blocked])
    check(r == .interrupted(gammaDelta), "pull: the agent no longer working or done after the keys: interrupted (\(r))")

    // r5 P2-3: the live IO checks the pane's agent once more right before the keys (a fresh herdr snapshot).
    let fake = FakeHerdr(path: NSTemporaryDirectory() + "hkq5-\(getpid()).sock")
    try fake.start()
    defer { fake.kill() }
    let liveIO = HerdrQueuePullIO(client: HerdrClient(session: HerdrSession(name: "fake", socketPath: fake.path)), paneId: "w1:p1", allowed: { true })
    let keyMethods: Set<String> = ["pane.send_keys", "pane.send_text", "pane.send_input"]
    func sentKeys(after n: Int) -> Int { fake.requests.dropFirst(n).filter { keyMethods.contains($0.method) }.count }
    var claude = working("claude"); claude.sessionId = "s1"
    fake.agents = #"[{"pane_id":"w1:p1","agent":"codex","name":"codex","agent_status":"working","agent_session":{"agent":"codex","kind":"id","source":"herdr:codex","value":"s1"}}]"#
    var n = fake.requests.count
    let toCodex = await liveIO.keys(["Up"], expect: claude)
    check(!toCodex && sentKeys(after: n) == 0, "pull: r5 P2-3: the live IO: Codex in the pane right before the keys: no key goes out")
    fake.agents = #"[{"pane_id":"w1:p1","agent":"claude","name":"claude","agent_status":"working","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"s1"}}]"#
    n = fake.requests.count
    let toClaude = await liveIO.keys(["Up"], expect: claude)
    check(toClaude && sentKeys(after: n) == 1, "pull: r5 P2-3: the live IO: the same Claude session: the key goes out (\(sentKeys(after: n)))")

    // r6 P2-3: Allow input is asked again after the snapshot, right before the keys (it may go off while herdr answers).
    var asks = 0
    let offIO = HerdrQueuePullIO(client: HerdrClient(session: HerdrSession(name: "fake", socketPath: fake.path)), paneId: "w1:p1",
                                 allowed: { asks += 1; return asks == 1 })
    n = fake.requests.count
    let offLate = await offIO.keys(["Up"], expect: claude)
    check(!offLate && sentKeys(after: n) == 0, "pull: r6 P2-3: input went off while the agent was read: no key goes out (\(asks) asks)")

    let flat = Set(allKeys.flatMap { $0 })
    check(flat.isSubset(of: QueuePull.allowedKeys) && !flat.contains { $0.lowercased().hasPrefix("esc") }, "pull: every key sent in every case is Up, shift+left or ctrl+u (the names herdr takes) (\(flat.sorted()))")
}

extension QueuePull.Outcome {
    var isRefused: Bool { if case .refused = self { true } else { false } }
    var isFailed: Bool { if case .failed = self { true } else { false } }
    var isPartial: Bool { if case .partial = self { true } else { false } }
    var why: String? { if case .partial(_, let w) = self { w } else { nil } }
}
func failedWhy(_ r: QueuePull.Outcome) -> String { if case .failed(let w) = r { w } else { "" } }
extension QueuePull.Outcome {
    var refusedWhy: String? { if case .refused(let w) = self { w } else { nil } }
}
