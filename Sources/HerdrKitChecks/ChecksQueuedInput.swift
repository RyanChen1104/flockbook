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
    func keys(_ k: [String]) async -> Bool { sent.append(k); return keysOn }
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
    let gammaDelta = "QC reply GAMMA\nQD reply DELTA"
    let gd: ClaudeQueueLog = ["QC reply GAMMA", "QD reply DELTA"]
    let u = ["ctrl+u"]

    // Claude Code: Up, then one Ctrl-U at a time; the box is read again before each and must still hold what Up
    // brought back, less the rows Ctrl-U took (Ctrl-U takes one row; an emptied row's line break takes one more).
    var (r, k) = await pull("claude", [two, pulledIn, pulledIn, oneRow, oneRow, "· Pouncing… (13s)\n" + empty], log: gd)
    check(r == .pulled(gammaDelta) && k == [["Up"], u, u, u], "pull: Claude: Up, then one Ctrl-U per key list until the box is empty (\(r), \(k))")
    check(kept.map(\.0) == [gammaDelta] && kept.first?.1 == 1, "pull: the text is kept after Up, before the first Ctrl-U (\(kept))")
    // The screen showed fewer rows than Up brought back (seen live: one row drawn, two queued): the composer gets every
    // line that came back, never only the expected ones (the rest would be cleared and lost).
    let more = claudeBox(["QK reply KILO", "QL reply LIMA"])
    (r, k) = await pull("claude", [claudeScreen(queued: ["QL reply LIMA"]), more, more, claudeBox(["QK reply KILO"]), empty], log: ["QK reply KILO", "QL reply LIMA"])
    check(r == .pulled("QK reply KILO\nQL reply LIMA"), "pull: more came back than the screen showed: all of it (\(r))")
    // A long message wraps in the input box: the text stays as queued, not cut at the wraps.
    let wrapped = claudeBox(["QW one two three", "four five"])
    (r, _) = await pull("claude", [claudeScreen(queued: ["QW one two three four five"]), wrapped, wrapped, claudeBox(["QW one two three"]), empty],
                        log: ["QW one two three four five"])
    check(r == .pulled("QW one two three four five"), "pull: a wrapped message comes back as queued (\(r))")

    // P2-5: CJK wraps anywhere in the box (56 columns here: 28 characters). The log's text comes back exactly.
    let cjk = String(repeating: "請檢查資料庫連線", count: 5)
    let cjkRows = [String(cjk.prefix(28)), String(cjk.dropFirst(28))]
    (r, k) = await pull("claude", [claudeScreen(queued: [cjk]), claudeBox(cjkRows), claudeBox(cjkRows), claudeBox([cjkRows[0]]), empty], log: [cjk])
    check(r == .pulled(cjk), "pull: CJK wrapped mid-word in the box comes back as the log has it (\(r))")
    // Up brought back something else than expected: it goes to the composer as it is, and the box is not cleared.
    let odd = claudeBox(["QZ something else"])
    (r, k) = await pull("claude", [two, odd, odd], log: gd)
    check(r.text == "QZ something else" && r.isPartial && k == [["Up"]], "pull: other text came back: to the composer, no Ctrl-U (\(r), \(k))")

    // P1-1: the owner types in the terminal while it is cleared: stop, no more keys, the text still goes to the composer.
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, claudeBox(["QC reply GAMMA", "QD reply DELTA and more"])], log: gd)
    check(r == .partial(gammaDelta, r.why ?? "") && k == [["Up"], u], "pull: the box changed between two Ctrl-U: stopped, the text kept (\(r), \(k))")
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, oneRow, claudeBox(["QC reply GAMMA typed"])], log: gd)
    check(r.isPartial && r.text == gammaDelta && k == [["Up"], u, u], "pull: text typed into a row Ctrl-U left: stopped, no more keys (\(r), \(k))")
    // P1-1: another agent in the pane after Up: no Ctrl-U at all.
    var other = working("claude"); other.sessionId = "another"
    (r, k) = await pull("claude", [two, pulledIn, pulledIn], log: gd, agents: [working("claude"), other])
    check(r.isPartial && r.text == gammaDelta && k == [["Up"]], "pull: another agent after Up: no Ctrl-U, the text kept (\(r), \(k))")
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, oneRow], log: gd, agents: [working("claude"), working("claude"), other])
    check(r.isPartial && r.text == gammaDelta && k == [["Up"], u], "pull: another agent between two Ctrl-U: stopped (\(k))")
    // P1-2: a failed read during or after the clearing: the text still comes back.
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, nil], log: gd)
    check(r.text == gammaDelta && k == [["Up"], u], "pull: the box cannot be read after a Ctrl-U: the text still goes to the composer (\(r))")
    (r, k) = await pull("claude", [two, nil], log: gd)
    check(r.text == gammaDelta && k == [["Up"]], "pull: the box cannot be read after Up: the text goes to the composer, no Ctrl-U (\(r))")
    // The text could not be kept: no Ctrl-U (the box keeps it), and it still goes to the composer.
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, oneRow, oneRow, empty], log: gd, saves: false)
    check(r.isPartial && r.text == gammaDelta && k == [["Up"]], "pull: not kept: no Ctrl-U (\(r), \(k))")
    // Ctrl-U never clears it: stop after a bounded number of keys.
    (r, k) = await pull("claude", [two, pulledIn], log: gd)
    check(r.isPartial && r.text == gammaDelta && k.count <= 7 && k.dropFirst().allSatisfy { $0 == u }, "pull: the box never empties: stopped after a few Ctrl-U (\(k.count - 1))")

    // Codex: Shift-Left takes the newest only.
    let cxQueued = codexScreen(queued: ["QB reply BETA", "QD reply DELTA"])
    let cxPulled = codexScreen(queued: ["QB reply BETA"], input: "› QD reply DELTA")
    (r, k) = await pull("codex", [cxQueued, cxPulled, cxPulled, codexScreen(queued: ["QB reply BETA"])])
    check(r == .pulled("QD reply DELTA") && k == [["shift+left"], u], "pull: Codex: Shift-Left takes the newest only (\(r), \(k))")
    // P2-4: indentation stays; a soft wrap is not a line break (Codex wraps at the pane's width less 3).
    let code = "if ready:\n    run()"
    let cxCode = codexScreen(queued: [], input: "› if ready:\n      run()")
    (r, k) = await pull("codex", [codexScreen(queued: ["if ready:\n        run()"]), cxCode, cxCode, codexScreen(queued: [], input: "› if ready:"), codexScreen(queued: [])])
    check(r.isRefused && k.isEmpty, "pull: r3 P2-1: Codex: a queued message on more than one row: refused before any key (\(r), \(k))")
    let long = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu"
    let rows = wrap(long, width: 37)   // 40 columns
    let cxLong = codexScreen(queued: [], input: "› " + rows.joined(separator: "\n  "))
    (r, k) = await pull("codex", [codexScreen(queued: [long]), cxLong, cxLong, codexScreen(queued: [])], cols: 40)
    check(rows.count > 1 && r.isFailed && r.text == nil && k == [["shift+left"]] && failedWhy(r).contains("terminal"),
          "pull: r3 P2-1: Codex: the box wraps it on more than one row: no Ctrl-U, no guess for the composer, edit it in the terminal (\(rows), \(r), \(k))")
    // r2 P2-5: a line break and a wrap look the same in the box (36 columns of text, a line break, then a word, in 37
    // columns). Flockbook cannot tell them apart: it sends no Ctrl-U, the box keeps the text exactly, the owner is told.
    let hard = String(repeating: "a", count: 36) + "\nnext"
    let cxHard = codexScreen(queued: [], input: "› " + String(repeating: "a", count: 36) + "\n  next")
    (r, k) = await pull("codex", [codexScreen(queued: [hard]), cxHard, cxHard, codexScreen(queued: [])], cols: 40)
    check(r.isFailed && r.text == nil && k == [["shift+left"]] && kept.isEmpty && failedWhy(r).contains("terminal"),
          "pull: r3 P2-1: a line break or a wrap, not known: no Ctrl-U, nothing kept, no guess for the composer (\(r), \(k))")
    // Claude Code: rows that the log's text does not match (or no log): no Ctrl-U either. One row: no line breaks to lose.
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, oneRow, empty])
    check(r.isRefused && k.isEmpty, "pull: r3 P2-1: Claude rows the log does not give exactly: refused before any key (\(r), \(k))")
    // The screen showed one row, the log had nothing, and Up brought back two: no guess either.
    (r, k) = await pull("claude", [claudeScreen(queued: ["QD reply DELTA"]), pulledIn, pulledIn, oneRow, empty])
    check(r.isFailed && r.text == nil && k == [["Up"]] && kept.isEmpty, "pull: r3 P2-1: more rows came back than the log gives: no Ctrl-U, no guess (\(r), \(k))")
    (r, k) = await pull("claude", [claudeScreen(queued: ["QC reply GAMMA"]), oneRow, oneRow, empty])
    check(r == .pulled("QC reply GAMMA") && k == [["Up"], u], "pull: one row without the log: cleared (\(r), \(k))")
    (r, k) = await pull("codex", [cxQueued, cxPulled, cxPulled, codexScreen(queued: ["QB reply BETA"])])
    check(r == .pulled("QD reply DELTA") && k == [["shift+left"], u], "pull: Codex: one row: cleared (\(r), \(k))")

    // r2 P1-4: the pull is bound to the agent's session: without one (nil or empty) Flockbook cannot tell another agent
    // of the same kind from it, so it refuses before any key.
    for sid in [nil, ""] as [String?] {
        var anon = working("claude"); anon.sessionId = sid
        (r, k) = await pull("claude", [two, pulledIn, pulledIn, oneRow, oneRow, empty], log: gd, expect: anon)
        check(r.isRefused && k.isEmpty, "pull: r2 P1-4: an agent without a session id (\(String(describing: sid))): refused, no key (\(r), \(k))")
    }
    var lost = working("claude"); lost.sessionId = nil
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, oneRow, oneRow, empty], log: gd, agents: [working("claude"), lost])
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
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, "  ⎿  Interrupted · What should Claude do instead?\n" + empty], log: gd)
    check(r == .interrupted(gammaDelta), "pull: an interrupt notice after the keys: interrupted, the text kept (\(r))")
    var blocked = working("claude"); blocked.status = .blocked
    (r, k) = await pull("claude", [two, pulledIn, pulledIn, empty], log: gd, agents: [working("claude"), working("claude"), working("claude"), blocked])
    check(r == .interrupted(gammaDelta), "pull: the agent no longer working or done after the keys: interrupted (\(r))")

    let flat = Set(allKeys.flatMap { $0 })
    check(flat.isSubset(of: QueuePull.allowedKeys) && !flat.contains { $0.lowercased().hasPrefix("esc") }, "pull: every key sent in every case is Up, shift+left or ctrl+u (the names herdr takes) (\(flat.sorted()))")
}

extension QueuePull.Outcome {
    var isRefused: Bool { if case .refused = self { true } else { false } }
    var isFailed: Bool { if case .failed = self { true } else { false } }
    var isPartial: Bool { if case .partial = self { true } else { false } }
    var why: String? { if case .partial(_, let w) = self { w } else { nil } }
}
func failedWhy(_ r: QueuePull.Outcome) -> String { if case .failed(let w) = r { w } else { "" }
}
