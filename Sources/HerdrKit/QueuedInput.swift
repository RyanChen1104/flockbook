import Foundation

/// Messages the owner typed while the agent works that the agent has not taken yet: Claude Code's and Codex's own
/// queues, shown faded at the end of the conversation. Flockbook keeps no queue of its own.
///
/// Claude Code: its session log records the queue (`queue-operation` lines), the screen confirms it is still open
/// ("ctrl+enter to send now" under the queued rows) and fills in text the log left out (an enqueue during compaction
/// has no content). Codex logs nothing until a message goes in: only its screen ("Queued follow-up inputs") shows it.
public struct QueuedInput: Codable, Hashable, Sendable {
    /// "claude" or "codex".
    public var agent: String
    /// Oldest first. Nil: the agent queued a message whose text neither the log nor the screen shows.
    public var items: [String?]
    /// The queue can be pulled back now: the agent's input box is empty and the queue is on screen.
    public var pullable: Bool
    public init(agent: String, items: [String?], pullable: Bool) { self.agent = agent; self.items = items; self.pullable = pullable }

    /// Claude Code pulls back every queued message as one text (one per line); Codex only the newest.
    public var pullsAll: Bool { agent == "claude" }

    /// The queue of a pane, or nil when none is open. `log`: the queue rebuilt from a Claude log (`ClaudeQueueLog`).
    public static func read(agent: Agent?, screen: String?, log: ClaudeQueueLog) -> QueuedInput? {
        guard let agent, agent.status == .working, let screen else { return nil }
        switch agent.kind {
        case "claude": return claude(screen: screen, log: log)
        case "codex": return codex(screen: screen)
        default: return nil
        }
    }

    // MARK: Claude Code

    static let claudeHint = "ctrl+enter to send now"
    static let claudePlaceholder = "Press up to edit queued messages"

    /// The queue as Claude Code shows it: the "❯" rows right above the "ctrl+enter to send now" line, oldest first
    /// (rows that continue one keep their indentation past the two-column margin), and whether its input box holds
    /// only the placeholder.
    public static func claudeScreen(_ screen: String) -> (items: [String], inputEmpty: Bool)? {
        let lines = screen.components(separatedBy: "\n")
        guard let hint = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == claudeHint }) else { return nil }
        var groups: [String] = [], cont: [String] = []
        var i = hint - 1
        while i >= 0 {
            let l = lines[i]
            if l.hasPrefix("❯ ") {
                groups.insert(([trailing(String(l.dropFirst(2)))] + cont.reversed()).joined(separator: "\n"), at: 0)
                cont = []
            } else if l.hasPrefix("  "), !l.trimmingCharacters(in: .whitespaces).isEmpty {
                cont.append(trailing(String(l.dropFirst(2))))
            } else { break }
            i -= 1
        }
        guard !groups.isEmpty else { return nil }
        let input = QueuePull.claudeBox(lines)
        return (groups, input == [claudePlaceholder])
    }

    /// The log and the screen, lined up by their text from the newest back (never by count alone). The screen may
    /// also show a sent prompt above the queue, and it may draw only the newest rows (right after an enqueue, or a
    /// short pane): log entries older than the rows it shows stay. Nothing proves such an entry stale, so the queue
    /// rather shows one too many (a pull then finds the box does not hold it and clears nothing). A log that does not
    /// line up with the screen (not caught up, or other text): the screen's rows.
    static func claude(screen: String, log: ClaudeQueueLog) -> QueuedInput? {
        guard let shown = claudeScreen(screen) else { return nil }
        let rows = shown.items, entries = log.items
        var m = 0
        while m < entries.count, m < rows.count, same(entries[entries.count - 1 - m], rows[rows.count - 1 - m]) { m += 1 }
        guard m > 0 else { return QueuedInput(agent: "claude", items: rows, pullable: shown.inputEmpty) }
        let matched: [String?] = (0..<m).reversed().map { (k: Int) -> String? in entries[entries.count - 1 - k] ?? rows[rows.count - 1 - k] }
        return QueuedInput(agent: "claude", items: Array(entries.dropLast(m)) + matched, pullable: shown.inputEmpty)
    }

    /// A log entry and a screen row are the same message: the same characters apart from spaces and line breaks (the
    /// screen wraps); a row cut with "…" matches the start. A log entry without text matches any row.
    static func same(_ entry: String?, _ row: String) -> Bool {
        guard let entry else { return true }
        let e = QueuePull.compact(entry), r = QueuePull.compact(row)
        return e == r || (r.hasSuffix("…") && e.hasPrefix(String(r.dropLast())))
    }

    /// Without trailing spaces (the screen pads rows); leading ones are the text's own indentation.
    static func trailing(_ s: String) -> String {
        var s = s.replacingOccurrences(of: "\u{a0}", with: " ")
        while s.last?.isWhitespace == true { s.removeLast() }
        return s
    }

    // MARK: Codex

    static let codexHeader = "• Queued follow-up inputs"
    static let codexHint = "⇧← edit last queued message"
    static let codexPlaceholder = "Ask Codex to do anything"

    /// The queue as Codex shows it ("↳" rows under "• Queued follow-up inputs"; rows that continue one keep their
    /// indentation past the four-column margin), and whether its input box holds only the placeholder.
    public static func codexScreen(_ screen: String) -> (items: [String], inputEmpty: Bool)? {
        let lines = screen.components(separatedBy: "\n")
        guard let head = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == codexHeader }) else { return nil }
        var items: [String] = []
        var margin = 4   // where a row's text starts: after "  ↳ "
        var i = head + 1
        while i < lines.count {
            let l = lines[i], t = l.trimmingCharacters(in: .whitespaces)
            if t == codexHint { break }
            if t.hasPrefix("↳ ") {
                margin = l.count - t.count + 2
                items.append(trailing(String(t.dropFirst(2))))
            } else if !t.isEmpty, l.hasPrefix(String(repeating: " ", count: margin)), !items.isEmpty {
                items[items.count - 1] += "\n" + trailing(String(l.dropFirst(margin)))
            } else { break }
            i += 1
        }
        guard !items.isEmpty else { return nil }
        return (items, QueuePull.codexBox(lines) == [codexPlaceholder])
    }

    static func codex(screen: String) -> QueuedInput? {
        codexScreen(screen).map { QueuedInput(agent: "codex", items: $0.items, pullable: $0.inputEmpty) }
    }
}

/// Claude Code's queue from its session log: `enqueue` adds (its `content`, or none during compaction), `remove`
/// takes the message the agent read mid-turn, `dequeue` the oldest at a turn's end, `popAll` the ones the owner pulled
/// back with Up.
public struct ClaudeQueueLog: Sendable, Hashable, ExpressibleByArrayLiteral {
    public private(set) var items: [String?] = []
    public init() {}
    public init(arrayLiteral items: String?...) { self.items = items }
    public init(_ items: [String?]) { self.items = items }

    public mutating func feed(_ o: [String: Any]) {
        guard o["type"] as? String == "queue-operation" else { return }
        // As written: a pull compares it with the agent's input box character for character.
        let content = o["content"] as? String
        switch o["operation"] as? String {
        case "enqueue":
            items.append(content)
        case "dequeue": if !items.isEmpty { items.removeFirst() }
        case "remove", "popAll":
            if let i = items.firstIndex(where: { $0 == content }) ?? items.firstIndex(where: { $0 == nil }) { items.remove(at: i) }
            else if content == nil, !items.isEmpty { items.removeFirst() }
        default: break
        }
    }
}

/// Pulls the agent's queue back into Flockbook's composer: Up (Claude Code: every queued message, one per line) or
/// Shift-Left (Codex: the newest), then Ctrl-U until the agent's input box is empty. Never Escape: in both agents it
/// interrupts the running turn, even with text in the input box.
public enum QueuePull {
    public enum Outcome: Equatable, Sendable {
        /// The text left the agent's queue: put it in the composer.
        case pulled(String)
        /// The text left the queue but the turn stopped (an interrupt notice, or the agent is no longer working or done).
        case interrupted(String)
        /// Nothing was sent.
        case refused(String)
        /// Keys went out but the screen did not change as expected; no more keys were sent.
        case failed(String)
        /// The text came back and goes to the composer, but the pull stopped before the agent's input box was empty
        /// (the reason): some of it may still be there.
        case partial(String, String)

        /// Why a partial pull stopped; nil for the others.
        public var partialReason: String? { if case .partial(_, let why) = self { why } else { nil } }
        public var isInterrupted: Bool { if case .interrupted = self { true } else { false } }
        /// The text for the composer, if any came back.
        public var text: String? {
            switch self {
            case .pulled(let t), .interrupted(let t), .partial(let t, _): t
            case .refused, .failed: nil
            }
        }
    }

    /// The only keys this feature ever sends.
    public static let allowedKeys: Set<String> = ["Up", "shift+left", "ctrl+u"]

    public static func pullKey(agent: String) -> String? {
        switch agent {
        case "claude": "Up"
        case "codex": "shift+left"
        default: nil
        }
    }

    /// Refuses a key list with anything outside `allowedKeys` (so never Escape, Enter or raw bytes).
    public static func safe(_ keys: [String]) -> Bool { !keys.isEmpty && keys.allSatisfy(allowedKeys.contains) }

    /// "Interrupted" notices on screen (Claude Code: "Interrupted · What should Claude do instead?"; Codex: "Conversation
    /// interrupted"). A rise between two reads means the turn stopped. "esc to interrupt" does not count.
    public static func interrupts(_ screen: String) -> Int {
        screen.lowercased().components(separatedBy: "interrupted").count - 1
    }

    /// The pane as the pull needs it. `keys` returns false when the keys did not go out (or input is off now).
    public protocol IO {
        func agent() async -> Agent?
        func screen() async -> String?
        /// Sends `keys` only if `expect` (the same kind and session) is still the pane's agent right before them.
        func keys(_ keys: [String], expect: Agent) async -> Bool
        func settle() async
        /// The pane's width in columns (where the agent wraps its input box). Nil: not known.
        func width() async -> Int?
    }

    /// Up or Shift-Left, then Ctrl-U one at a time. Before the first Ctrl-U the text Up brought back goes to `keep`
    /// (saved until a composer has it; false: no Ctrl-U at all). Before each Ctrl-U the pull reads the pane again: the
    /// same agent, and an input box that still holds what came back less the rows Ctrl-U took; anything else stops it,
    /// with no more keys. Every key list goes out only after a fresh read finds the same agent. Only text the box holds
    /// exactly as the log has it goes on (to `keep` and the composer); anything else goes nowhere.
    public static func run(expect: Agent, log: ClaudeQueueLog, io: some IO, keep: @escaping @MainActor @Sendable (String) -> Bool = { _ in true }) async -> Outcome {
        guard let key = pullKey(agent: expect.kind) else { return .refused("This agent has no queue Flockbook can pull back.") }
        // Only Claude Code's log gives queued text exactly. Codex shows its queue on screen only, where trailing blank
        // lines and spaces are gone and a line break looks like wrapping: no text Flockbook could take is sure to be it.
        guard expect.kind == "claude" else {
            return .refused("Codex shows its queue only on screen, where Flockbook cannot read the text exactly. Edit it in Codex's terminal (Shift+Left takes back the newest). Nothing was sent.")
        }
        guard bound(expect) else {
            return .refused("Flockbook cannot tell which agent session runs in this pane, so it does not pull back. Nothing was sent.")
        }
        guard let now = await io.agent(), same(now, expect) else {
            return .refused("Another agent is in this pane now. Nothing was sent.")
        }
        guard now.status == .working else { return .refused("The agent is not working, so nothing is queued. Nothing was sent.") }
        guard let before = await io.screen(), let q = QueuedInput.read(agent: now, screen: before, log: log) else {
            return .refused("No queued message on screen. Nothing was sent.")
        }
        guard q.pullable else { return .refused("The agent's input box is not empty. Nothing was sent.") }
        let pulled = q.pullsAll ? q.items : Array(q.items.suffix(1))
        guard pulled.allSatisfy({ $0 != nil }) else { return .refused("The queued text cannot be read yet. Nothing was sent.") }
        let expected = pulled.compactMap { $0 }.joined(separator: "\n")
        // Not exactly in the log (not caught up, or text the log left out): the screen's rows are no proof of the
        // text (trailing spaces and blank lines are gone, a line break looks like wrapping). The terminal keeps it.
        let fromLog = log.items.allSatisfy { $0 != nil } && same(log.items.compactMap { $0 }.joined(separator: "\n"), expected)
        guard fromLog else {
            return .refused("Flockbook cannot read this queued text exactly yet. Edit it in the agent's terminal, or try again in a moment. Nothing was sent.")
        }
        // The box must show the text character for character: no wrapped row, no trailing space or blank line (the
        // screen drops them), every row on screen. Else no key: the queue keeps it.
        guard shows(expected, screen: before) else {
            return .refused("This queued text is too long or has spaces or blank lines that the agent's input box does not show, so Flockbook cannot check it exactly. Edit it in the agent's terminal. Nothing was sent.")
        }

        switch await send([key], io, expect) {
        case .sent: break
        case .off: return .refused("Input is off. Nothing was sent.")
        case .otherAgent: return .refused("Another agent is in this pane now. Nothing was sent.")
        }
        await io.settle()
        let check = "Check the agent's terminal before you send it."
        let edit = "It may be in the agent's input box now: edit it in the terminal."
        guard let shown = await io.screen() else {
            // Up went out and nothing shows the box holds exactly the text: it goes nowhere, the box is left alone.
            return .failed("Flockbook could not read the agent's input box after the pull, so it did not take the text or clear it. \(edit)")
        }
        // What came back is what the input box holds now. It may hold more than the screen showed (seen live): then
        // all of it goes to the composer, so Ctrl-U never clears text the owner did not get back.
        let back = box(shown, agent: expect.kind)
        guard !back.isEmpty, back != [placeholder(expect.kind)] else {
            return .failed("The queued text did not come back to the input box. It is still queued; nothing was cleared.")
        }
        // Before any way out that gives text on: the box must hold the log's text character for character. Anything
        // else is not the owner's text for sure, so it goes nowhere: not kept, not in a composer, not cleared.
        guard exact(rawBox(shown), expected) else {
            return .failed("The agent's input box did not hold exactly the queued text, so Flockbook did not take it or clear it. \(edit)")
        }
        let taken = expected
        guard await keep(taken) else {
            return .partial(taken, "Flockbook could not save the text, so it did not clear the agent's input box. \(check)")
        }

        // One Ctrl-U at a time (it takes one row; an emptied row's line break takes one more), each after a read that
        // finds the same agent and only rows of the text left, as drawn (an emptied last row holds nothing).
        let raw = rawBox(shown)
        var left = raw.count, after = shown
        let most = 2 * raw.count + 2
        for step in 0...most {
            guard let a = await io.agent(), same(a, expect) else {
                return .partial(taken, "Another agent is in this pane now, so Flockbook stopped clearing its input box. \(check)")
            }
            guard let s = await io.screen() else {
                return .partial(taken, "Flockbook could not read the agent's input box, so it stopped clearing it. \(check)")
            }
            after = s
            var rows = rawBox(s)
            while rows.last == "" { rows.removeLast() }
            // None of it left: an empty box or the placeholder. Anything else must be the text's first rows exactly.
            if rows.isEmpty || rows == [placeholder(expect.kind)] { left = 0; break }
            guard rows.count <= left, zip(raw, rows).allSatisfy({ same($0, $1) }) else {
                return .partial(taken, "The agent's input box changed while Flockbook cleared it, so it stopped. \(check)")
            }
            left = rows.count
            guard step < most else { break }
            switch await send(["ctrl+u"], io, expect) {
            case .sent: break
            case .off: return .partial(taken, "Input went off while Flockbook cleared the agent's input box. \(check)")
            case .otherAgent: return .partial(taken, "Another agent is in this pane now, so Flockbook stopped clearing its input box. \(check)")
            }
            await io.settle()
        }
        guard left == 0 else { return .partial(taken, "The text is still in the agent's input box. \(check)") }
        let status = await io.agent()?.status
        if interrupts(after) > interrupts(before) || !(status == .working || status == .idle || status == .done) {
            return .interrupted(taken)
        }
        return .pulled(taken)
    }

    /// The agent the pull checked: the same kind and session, both known.
    private static func same(_ a: Agent, _ b: Agent) -> Bool { bound(a) && a.kind == b.kind && a.sessionId == b.sessionId }
    /// The agent has a session id: without one another agent of its kind in the pane looks the same.
    private static func bound(_ a: Agent) -> Bool { !(a.sessionId ?? "").isEmpty }

    /// The text without spaces and line breaks: the screen wraps rows (CJK anywhere, words at spaces).
    static func compact(_ s: String) -> String { String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init)) }

    enum Sent { case sent, off, otherAgent }

    /// Each key list goes out only after a fresh read finds the agent the pull checked still in the pane (the IO checks
    /// it again right before the keys).
    private static func send(_ keys: [String], _ io: some IO, _ expect: Agent) async -> Sent {
        guard safe(keys) else { return .off }
        guard let a = await io.agent(), same(a, expect) else { return .otherAgent }
        return await io.keys(keys, expect: expect) ? .sent : .off
    }

    /// The box rows are the text, character for character: one row per line, nothing joined, trimmed or guessed.
    static func exact(_ rows: [String], _ text: String) -> Bool { same(rows.joined(separator: "\n"), text) }

    /// The same Unicode scalars (Swift's `==` takes canonically equal text as equal: U+F900 and U+8C48).
    static func same(_ a: String, _ b: String) -> Bool { a.unicodeScalars.elementsEqual(b.unicodeScalars) }

    /// The most rows `visibleText` gives.
    static let visibleRows = 60

    /// The input box can show `text` character for character on `screen` (Claude Code, before the pull): only
    /// characters of a known width, every line on one row (narrower than the box), no line that ends in a space or
    /// looks like the box's rule, no blank line at the end, and all the lines on screen with the box's rules and
    /// what is under it.
    static func shows(_ text: String, screen: String) -> Bool {
        guard !text.isEmpty, let width = textWidth(screen, agent: "claude", paneWidth: nil) else { return false }
        let shown = screen.components(separatedBy: "\n")
        guard let rule = shown.lastIndex(where: isRule) else { return false }
        // Under the box: the bottom rule and the lines below it; over it: the top rule and one more line.
        let room = min(shown.count, visibleRows) - (shown.count - rule) - 2
        let lines = text.components(separatedBy: "\n")
        guard lines.count <= room, lines.last?.isEmpty == false else { return false }
        return lines.allSatisfy { l in
            guard let cols = knownColumns(l) else { return false }
            return cols < width && l.last != " " && !(!l.isEmpty && l.unicodeScalars.allSatisfy { (0x2500...0x257F).contains($0.value) })
        }
    }

    /// The columns of `s` when every character's width is sure: printable ASCII (1), CJK and fullwidth (2), one
    /// scalar each, no combining mark. Nil for anything else (emoji, combining marks, joiners, tabs, no-break spaces).
    static func knownColumns(_ s: String) -> Int? {
        var n = 0
        for c in s {
            guard c.unicodeScalars.count == 1, let u = c.unicodeScalars.first else { return nil }
            // A combining mark (U+3099, U+302A…) has no width of its own: the screen puts it on the column before.
            switch u.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return nil
            default: break
            }
            let v = u.value
            switch v {
            case 0x20...0x7E: n += 1
            case 0x3000...0x303E, 0x3041...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
                 0xFF01...0xFF60, 0xFFE0...0xFFE6: n += 2
            default: return nil
            }
        }
        return n
    }

    /// The columns a row of text may fill: Claude Code wraps at its rule's width less 4, Codex at the pane's less 3
    /// (both seen live: Claude Code 2.1, Codex 0.163).
    static func textWidth(_ screen: String, agent: String, paneWidth: Int?) -> Int? {
        if agent == "claude" {
            let lines = screen.components(separatedBy: "\n")
            return lines.last(where: isRule).map { $0.trimmingCharacters(in: .whitespaces).count - 4 }
        }
        return paneWidth.map { $0 - 3 }
    }

    static func isRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= 10 && t.allSatisfy { $0 == "─" }
    }

    /// The input box's placeholder when the queue is open.
    static func placeholder(_ agent: String) -> String {
        agent == "claude" ? QueuedInput.claudePlaceholder : QueuedInput.codexPlaceholder
    }

    /// The agent's input box rows, without the box's margin (the prompt mark, then two columns) and trailing
    /// spaces; a row's own indentation stays. Blank rows at the end are dropped.
    static func box(_ screen: String, agent: String) -> [String] {
        let lines = screen.components(separatedBy: "\n")
        return agent == "claude" ? claudeBox(lines) : codexBox(lines)
    }

    /// Claude Code's input box rows as the screen has them: only the box's two-column margin is taken off (the prompt
    /// mark and its space on the first row, two columns on the others), nothing trimmed or replaced.
    static func rawBox(_ screen: String) -> [String] {
        let lines = screen.components(separatedBy: "\n")
        let rules = lines.indices.filter { isRule(lines[$0]) }
        guard rules.count >= 2 else { return [] }
        let margin: Set<Character> = [" ", "\u{a0}"]
        return lines[(rules[rules.count - 2] + 1)..<rules[rules.count - 1]].enumerated().map { i, l in
            if i == 0 { return l.first == "❯" ? String(l.dropFirst(2)) : l }
            return l.prefix(2).count == 2 && l.prefix(2).allSatisfy(margin.contains) ? String(l.dropFirst(2)) : l
        }
    }

    /// Claude Code: the rows between the last two rule lines; the first starts with "❯ ".
    static func claudeBox(_ lines: [String]) -> [String] {
        let rules = lines.indices.filter { isRule(lines[$0]) }
        guard rules.count >= 2 else { return [] }
        let (a, b) = (rules[rules.count - 2], rules[rules.count - 1])
        return rows(Array(lines[(a + 1)..<b]), mark: "❯")
    }

    /// Codex: the last row that starts with "› ", and the rows under it down to the footer (the line with the model's
    /// "% left" or "? for shortcuts").
    static func codexBox(_ lines: [String]) -> [String] {
        guard let i = lines.lastIndex(where: { $0.hasPrefix("› ") }) else { return [] }
        guard let end = lines[(i + 1)...].firstIndex(where: { $0.contains("% left") || $0.contains("? for shortcuts") }) else { return [] }
        return rows(Array(lines[i..<end]), mark: "›")
    }

    private static func rows(_ lines: [String], mark: Character) -> [String] {
        var out = lines.enumerated().map { i, l -> String in
            let l = l.replacingOccurrences(of: "\u{a0}", with: " ")
            if i == 0, l.first == mark { return QueuedInput.trailing(String(l.dropFirst(2))) }
            return QueuedInput.trailing(l.hasPrefix("  ") ? String(l.dropFirst(2)) : l)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out
    }
}

/// QueuePull on a live pane: a fresh snapshot for the agent, the visible screen, named keys through herdr. `allowed`
/// is asked right before each key list (Allow input, the device's level).
public struct HerdrQueuePullIO: QueuePull.IO {
    public let client: HerdrClient
    public let paneId: String
    public let allowed: @MainActor @Sendable () -> Bool
    public init(client: HerdrClient, paneId: String, allowed: @escaping @MainActor @Sendable () -> Bool) {
        self.client = client; self.paneId = paneId; self.allowed = allowed
    }
    public func agent() async -> Agent? {
        (try? await client.snapshot())?.flatMap(\.tabs).flatMap(\.panes).first { $0.id == paneId }?.agent
    }
    public func screen() async -> String? { try? await client.visibleText(paneId: paneId) }
    public func keys(_ keys: [String], expect: Agent) async -> Bool {
        guard QueuePull.safe(keys), await allowed() else { return false }
        // The last check before the keys: the pane still runs the agent the pull checked.
        guard let a = await agent(), a.kind == expect.kind, !(a.sessionId ?? "").isEmpty, a.sessionId == expect.sessionId else { return false }
        // Input may have gone off while herdr answered.
        guard await allowed() else { return false }
        return (try? await client.sendNamedKeys(keys, to: paneId)) != nil
    }
    public func settle() async { try? await Task.sleep(for: .milliseconds(400)) }
    /// herdr's layout for the pane (read-only).
    public func width() async -> Int? { await client.paneWidth(paneId: paneId) }
}

extension HerdrClient {
    /// The pane's width in columns, from herdr's layout (read-only). Nil: not known.
    public func paneWidth(paneId: String) async -> Int? {
        guard let data = try? await rawRequest(method: "pane.layout", params: ["pane_id": paneId]),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layout = (o["result"] as? [String: Any])?["layout"] as? [String: Any],
              let panes = layout["panes"] as? [[String: Any]],
              let p = panes.first(where: { $0["pane_id"] as? String == paneId }) else { return nil }
        return (p["rect"] as? [String: Any])?["width"] as? Int
    }
}
