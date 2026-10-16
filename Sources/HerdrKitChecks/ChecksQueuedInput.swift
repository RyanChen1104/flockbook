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

/// A pane for QueuePull: screens and agents in the order the pull reads them; every key list it sends.
@MainActor private final class FakePane: QueuePull.IO {
    var screens: [String]
    var agents: [Agent?]
    var sent: [[String]] = []
    var keysOn = true
    init(screens: [String], agents: [Agent?]) { self.screens = screens; self.agents = agents }
    func agent() async -> Agent? { agents.count > 1 ? agents.removeFirst() : agents.first ?? nil }
    func screen() async -> String? { screens.count > 1 ? screens.removeFirst() : screens.first }
    func keys(_ k: [String]) async -> Bool { sent.append(k); return keysOn }
    func settle() async {}
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
    check(QueuedInput.read(agent: working("claude"), screen: claudeScreen(queued: ["QD reply DELTA"]), log: ["stale", "QD reply DELTA"])?.items == ["QD reply DELTA"],
          "queue: an entry the log never closed is dropped when the screen shows fewer")
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
    func pull(_ kind: String, _ screens: [String], agents: [Agent?]? = nil, log: [String?] = [], keysOn: Bool = true) async -> (QueuePull.Outcome, [[String]]) {
        let io = FakePane(screens: screens, agents: agents ?? [working(kind)])
        io.keysOn = keysOn
        let r = await QueuePull.run(expect: working(kind), log: log, io: io)
        allKeys += io.sent
        return (r, io.sent)
    }
    let empty = rule + "\n❯ \n" + rule
    let pulledIn = "⏺ ALPHA\n· Pouncing… (12s)\n" + rule + "\n❯ QC reply GAMMA\n  QD reply DELTA\n" + rule

    var (r, k) = await pull("claude", [two, pulledIn, "· Pouncing… (13s)\n" + empty])
    check(r == .pulled("QC reply GAMMA\nQD reply DELTA") && k == [["Up"], ["ctrl+u", "ctrl+u", "ctrl+u"]], "pull: Claude: Up, then Ctrl-U per input row and one more; every queued message, one per line (\(r), \(k))")
    // The screen showed fewer rows than Up brought back (seen live: one row drawn, two queued): the composer gets every
    // line that came back, never only the expected ones (the rest would be cleared and lost).
    let more = "⏺ ALPHA\n" + rule + "\n❯ QK reply KILO\n  QL reply LIMA\n" + rule
    (r, k) = await pull("claude", [claudeScreen(queued: ["QL reply LIMA"]), more, "· Pouncing… (13s)\n" + empty])
    check(r == .pulled("QK reply KILO\nQL reply LIMA") && k == [["Up"], ["ctrl+u", "ctrl+u", "ctrl+u"]], "pull: more came back than the screen showed: all of it (\(r))")
    // A long message wraps in the input box: the text stays as queued, not cut at the wraps.
    let wrapped = "⏺ ALPHA\n" + rule + "\n❯ QW one two three\n  four five\n" + rule
    (r, _) = await pull("claude", [claudeScreen(queued: ["QW one two three four five"]), wrapped, "· Pouncing… (13s)\n" + empty])
    check(r == .pulled("QW one two three four five"), "pull: a wrapped message comes back as queued (\(r))")
    (r, _) = await pull("claude", [two, pulledIn, "⏺ ALPHA\n" + rule + "\n❯ QD reply DELTA\n" + rule])
    check(r.isFailed, "pull: any pulled line left in the input box: failed")
    let cxQueued = codexScreen(queued: ["QB reply BETA", "QD reply DELTA"])
    let cxPulled = codexScreen(queued: ["QB reply BETA"], input: "› QD reply DELTA")
    (r, k) = await pull("codex", [cxQueued, cxPulled, codexScreen(queued: ["QB reply BETA"])])
    check(r == .pulled("QD reply DELTA") && k == [["shift+left"], ["ctrl+u", "ctrl+u"]], "pull: Codex: Shift-Left takes the newest only (\(r), \(k))")

    (r, k) = await pull("claude", [claudeScreen(queued: ["QC"], input: "❯ half typed")])
    check(r.isRefused && k.isEmpty, "pull: input box not empty: refused, no key")
    var notWorking = working("claude"); notWorking.status = .done
    (r, k) = await pull("claude", [two], agents: [notWorking])
    check(r.isRefused && k.isEmpty, "pull: the turn ended: refused, no key")
    var other = working("claude"); other.sessionId = "another"
    (r, k) = await pull("claude", [two], agents: [other])
    check(r.isRefused && k.isEmpty, "pull: another agent in the pane: refused, no key")
    (r, k) = await pull("claude", ["⏺ nothing queued\n" + empty])
    check(r.isRefused && k.isEmpty, "pull: no queue on screen: refused, no key")
    (r, k) = await pull("claude", [two], keysOn: false)
    check(r.isRefused && k == [["Up"]], "pull: input went off: nothing went out, no more keys")
    (r, k) = await pull("claude", [two, two])
    check(r.isFailed && k == [["Up"]], "pull: the text did not come back: failed, no Ctrl-U")
    (r, k) = await pull("claude", [two, pulledIn, pulledIn])
    check(r.isFailed && k.count == 2, "pull: the text stays in the input box: failed")
    (r, k) = await pull("claude", [two, pulledIn, "  ⎿  Interrupted · What should Claude do instead?\n" + empty])
    check(r == .interrupted("QC reply GAMMA\nQD reply DELTA"), "pull: an interrupt notice after the keys: interrupted, the text kept (\(r))")
    var blocked = working("claude"); blocked.status = .blocked
    (r, k) = await pull("claude", [two, pulledIn, empty], agents: [working("claude"), blocked])
    check(r == .interrupted("QC reply GAMMA\nQD reply DELTA"), "pull: the agent no longer working or done after the keys: interrupted (\(r))")

    let flat = Set(allKeys.flatMap { $0 })
    check(flat.isSubset(of: QueuePull.allowedKeys) && !flat.contains { $0.lowercased().hasPrefix("esc") }, "pull: every key sent in every case is Up, shift+left or ctrl+u (the names herdr takes) (\(flat.sorted()))")
}

extension QueuePull.Outcome {
    var isRefused: Bool { if case .refused = self { true } else { false } }
    var isFailed: Bool { if case .failed = self { true } else { false } }
}
