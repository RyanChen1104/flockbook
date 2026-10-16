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
    public static func read(agent: Agent?, screen: String?, log: [String?]) -> QueuedInput? {
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

    /// The queue as Claude Code shows it: the "❯" rows right above the "ctrl+enter to send now" line, oldest first,
    /// and whether its input box holds only the placeholder.
    public static func claudeScreen(_ screen: String) -> (items: [String], inputEmpty: Bool)? {
        let lines = screen.components(separatedBy: "\n")
        guard let hint = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == claudeHint }) else { return nil }
        var groups: [String] = [], cont: [String] = []
        var i = hint - 1
        while i >= 0 {
            let l = lines[i]
            if l.hasPrefix("❯ ") {
                groups.insert(([String(l.dropFirst(2))] + cont.reversed()).joined(separator: "\n").trimmingCharacters(in: .whitespaces), at: 0)
                cont = []
            } else if l.hasPrefix("  "), !l.trimmingCharacters(in: .whitespaces).isEmpty {
                cont.append(l.trimmingCharacters(in: .whitespaces))
            } else { break }
            i -= 1
        }
        guard !groups.isEmpty else { return nil }
        let input = claudeInput(lines)
        return (groups, input.count == 1 && input[0] == "❯ " + claudePlaceholder)
    }

    /// The rows of Claude Code's input box: between the last two rule lines.
    static func claudeInput(_ lines: [String]) -> [String] {
        let rules = lines.indices.filter { i in
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            return t.count >= 10 && t.allSatisfy { $0 == "─" }
        }
        guard rules.count >= 2 else { return [] }
        let (a, b) = (rules[rules.count - 2], rules[rules.count - 1])
        return lines[(a + 1)..<b].map { $0.replacingOccurrences(of: "\u{a0}", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func claude(screen: String, log: [String?]) -> QueuedInput? {
        guard let shown = claudeScreen(screen) else { return nil }
        // The log is exact; the screen may also show a sent prompt right above the queue. So the log sets the count,
        // and the screen's newest rows fill in what the log left out. A queue the log has not caught up with yet:
        // the screen's rows.
        guard !log.isEmpty else { return QueuedInput(agent: "claude", items: shown.items, pullable: shown.inputEmpty) }
        // More in the log than on screen: older entries the log never closed (a restart). The newest ones count.
        let log = Array(log.suffix(shown.items.count))
        let rows = Array(shown.items.suffix(log.count))
        let pad = log.count - rows.count
        let items = log.enumerated().map { i, t in t ?? (i >= pad ? rows[i - pad] : nil) }
        return QueuedInput(agent: "claude", items: items, pullable: shown.inputEmpty)
    }

    // MARK: Codex

    static let codexHeader = "• Queued follow-up inputs"
    static let codexHint = "⇧← edit last queued message"
    static let codexPlaceholder = "› Ask Codex to do anything"

    /// The queue as Codex shows it ("↳" rows under "• Queued follow-up inputs"), and whether its input box holds
    /// only the placeholder (the row after the "⇧←" hint).
    public static func codexScreen(_ screen: String) -> (items: [String], inputEmpty: Bool)? {
        let lines = screen.components(separatedBy: "\n")
        guard let head = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == codexHeader }) else { return nil }
        var items: [String] = []
        var i = head + 1
        var hint: Int?
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == codexHint { hint = i; break }
            if t.hasPrefix("↳ ") { items.append(String(t.dropFirst(2))) }
            else if !t.isEmpty, lines[i].hasPrefix("    "), !items.isEmpty { items[items.count - 1] += "\n" + t }
            else { break }
            i += 1
        }
        guard !items.isEmpty else { return nil }
        let input = hint.flatMap { h in lines[(h + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        return (items, input?.trimmingCharacters(in: .whitespaces) == codexPlaceholder)
    }

    static func codex(screen: String) -> QueuedInput? {
        codexScreen(screen).map { QueuedInput(agent: "codex", items: $0.items, pullable: $0.inputEmpty) }
    }
}

/// Claude Code's queue from its session log: `enqueue` adds (its `content`, or none during compaction), `remove`
/// takes the message the agent read mid-turn, `dequeue` the oldest at a turn's end, `popAll` the ones the owner pulled
/// back with Up.
public struct ClaudeQueueLog: Sendable, Equatable {
    public private(set) var items: [String?] = []
    public init() {}

    public mutating func feed(_ o: [String: Any]) {
        guard o["type"] as? String == "queue-operation" else { return }
        let content = (o["content"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch o["operation"] as? String {
        case "enqueue": items.append(content)
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
    }

    /// The only keys this feature ever sends.
    public static let allowedKeys: Set<String> = ["Up", "S-Left", "C-u"]

    public static func pullKey(agent: String) -> String? {
        switch agent {
        case "claude": "Up"
        case "codex": "S-Left"
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
        func keys(_ keys: [String]) async -> Bool
        func settle() async
    }

    public static func run(expect: Agent, log: [String?], io: some IO) async -> Outcome {
        guard let key = pullKey(agent: expect.kind) else { return .refused("This agent has no queue Flockbook can pull back.") }
        guard let now = await io.agent(), now.kind == expect.kind, now.sessionId == expect.sessionId else {
            return .refused("Another agent is in this pane now. Nothing was sent.")
        }
        guard now.status == .working else { return .refused("The agent is not working, so nothing is queued. Nothing was sent.") }
        guard let before = await io.screen(), let q = QueuedInput.read(agent: now, screen: before, log: log) else {
            return .refused("No queued message on screen. Nothing was sent.")
        }
        guard q.pullable else { return .refused("The agent's input box is not empty. Nothing was sent.") }
        let pulled = q.pullsAll ? q.items : Array(q.items.suffix(1))
        guard pulled.allSatisfy({ $0 != nil }) else { return .refused("The queued text cannot be read yet. Nothing was sent.") }
        let text = pulled.compactMap { $0 }.joined(separator: "\n")
        let first = text.components(separatedBy: "\n").first ?? text

        guard await send([key], io) else { return .refused("Input is off. Nothing was sent.") }
        await io.settle()
        guard let moved = await io.screen(), inputRows(moved, agent: expect.kind).contains(where: { $0.contains(first) }) else {
            return .failed("The queued text did not come back to the input box. Check the agent's terminal.")
        }
        // One Ctrl-U per input row (it clears one line), and one more.
        let rows = max(1, inputRows(moved, agent: expect.kind).count)
        guard await send(Array(repeating: "C-u", count: rows + 1), io) else {
            return .failed("The text is in the agent's input box: input went off before it was cleared.")
        }
        await io.settle()
        guard let after = await io.screen(), !inputRows(after, agent: expect.kind).contains(where: { $0.contains(first) }) else {
            return .failed("The text is still in the agent's input box. Check the agent's terminal.")
        }
        let status = await io.agent()?.status
        if interrupts(after) > interrupts(before) || !(status == .working || status == .idle || status == .done) {
            return .interrupted(text)
        }
        return .pulled(text)
    }

    private static func send(_ keys: [String], _ io: some IO) async -> Bool {
        guard safe(keys) else { return false }
        return await io.keys(keys)
    }

    /// The agent's input box rows (Claude Code: between the last two rules; Codex: the "›" row above the footer and
    /// the rows that continue it).
    static func inputRows(_ screen: String, agent: String) -> [String] {
        let lines = screen.components(separatedBy: "\n")
        if agent == "claude" { return QueuedInput.claudeInput(lines) }
        guard let i = lines.lastIndex(where: { $0.hasPrefix("› ") }) else { return [] }
        var rows = [String(lines[i].dropFirst(2))]
        for l in lines[(i + 1)...] {
            guard l.hasPrefix("  "), !l.trimmingCharacters(in: .whitespaces).isEmpty, !l.contains(" · ") else { break }
            rows.append(l.trimmingCharacters(in: .whitespaces))
        }
        return rows
    }
}
