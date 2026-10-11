import Foundation

/// Allow / Deny buttons on the "needs you" system notification for a permission prompt.
///
/// Buttons only for a permission prompt on screen (`PermissionGate`): input is on and the agent is blocked. The id is the
/// log's pending tool call, or the prompt box on screen when there is none (a Claude without a transcript). Only Claude Code:
/// `ApprovalKeys` are verified for it alone. A question picker never gets buttons (the tab opens). An action re-reads
/// the pane first and answers only the prompt the notification was posted for; otherwise the tab opens.
public enum ApprovalNotice {
    public static let category = "approval"

    public enum Action: String, CaseIterable, Sendable {
        case allow = "approval.allow"
        case deny = "approval.deny"
        /// The `allow` argument of `HerdrClient.respond`, the call the approval card makes.
        public var allows: Bool { self == .allow }
    }

    /// The blocked pane at one moment: what the app knows plus the visible screen.
    public struct PaneState: Sendable, Hashable {
        public var agentKind: String
        public var blocked: Bool
        /// The tool call the log ends with, still without a result.
        public var pendingToolUseId: String?
        public var screen: String
        public init(agentKind: String, blocked: Bool, pendingToolUseId: String?, screen: String) {
            self.agentKind = agentKind; self.blocked = blocked; self.pendingToolUseId = pendingToolUseId; self.screen = screen
        }
    }

    /// The ids of the prompt the pane shows now: the log's pending tool call and the prompt box on screen. Empty: no
    /// buttons. The screen id covers a Claude that keeps no transcript and a log that lags the screen.
    static func promptIDs(_ s: PaneState, writes: Bool) -> [String] {
        guard writes, s.blocked, s.agentKind == "claude",
              QuestionAdapter.claudeScreen(s.screen) == nil,
              let onScreen = screenPrompt(s.screen) else { return [] }
        return [s.pendingToolUseId, onScreen].compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// The prompt a notification's buttons answer: the pending tool call's id, else the prompt on screen. Nil: no buttons.
    public static func prompt(_ s: PaneState, writes: Bool) -> String? { promptIDs(s, writes: writes).first }

    /// Claude's permission prompt box on screen. `tool` = the first word of its header ("Bash command" -> "Bash").
    /// `lines` = the whole box, trimmed: from below the box's top rule (or the screen top) down to the last option, without
    /// what changes while the prompt stays: blank lines, the rotating "Tip:" line, the auto-deny countdown and the cursor `❯`.
    struct ScreenBox: Sendable, Hashable {
        var header: String
        var tool: String
        var command: String
        var lines: [String]
    }

    /// "⚠ Claude Code will automatically deny this request in 1:23, …": its time changes every second.
    static func isCountdown(_ line: String) -> Bool {
        line.hasPrefix("⚠") && line.firstMatch(of: /\b\d{1,2}:\d{2}\b/) != nil
    }

    static func screenBox(_ screen: String) -> ScreenBox? {
        let raw = screen.components(separatedBy: "\n")
        guard let ask = raw.lastIndex(where: { $0.contains(PermissionGate.promptMarker) }),
              QuestionAdapter.claudeScreen(screen) == nil else { return nil }
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }
        let top = raw[..<ask].lastIndex { trim($0).hasPrefix("─") }.map { $0 + 1 } ?? 0
        // Options: down to the first blank line or the key help line.
        var end = ask
        while end + 1 < raw.count, !trim(raw[end + 1]).isEmpty, !trim(raw[end + 1]).hasPrefix("Esc to cancel") { end += 1 }
        let box = raw[top...end].map { l -> String in
            let t = trim(l)
            return t.hasPrefix("❯") ? trim(String(t.dropFirst())) : t
        }.filter { !$0.isEmpty && !$0.hasPrefix("Tip:") && !isCountdown($0) }
        guard let header = box.first, header != box.last else { return nil }
        let isRule: (String) -> Bool = { $0.hasPrefix("╌") }
        let askAt = box.lastIndex { $0.contains(PermissionGate.promptMarker) } ?? box.count
        let body = Array(box[1..<askAt])
        let command: [String]
        if let r1 = body.firstIndex(where: isRule), let r2 = body[(r1 + 1)...].firstIndex(where: isRule) {
            command = Array(body[(r1 + 1)..<r2])
        } else {
            command = body.filter { !isRule($0) }
        }
        let tool = String(header.split(separator: " ").first ?? "")
        return ScreenBox(header: header, tool: tool, command: command.joined(separator: "\n"), lines: box)
    }

    /// Id of the permission prompt on screen: a hash of the tool name and the whole box (header, command, question and
    /// options), so another tool, command or option list is another prompt. Stable across launches. Nil: no prompt.
    public static func screenPrompt(_ screen: String) -> String? {
        guard let box = screenBox(screen) else { return nil }
        let text = "tool:\(box.tool)\n" + box.lines.joined(separator: "\n")
        var h: UInt64 = 0xcbf29ce484222325   // FNV-1a (Hasher is seeded per launch)
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return "screen-" + String(h, radix: 16)
    }

    /// The approval card's request read from the screen, for a prompt the log does not have (no transcript, or the log
    /// lags). Its `toolUseId` is `screenPrompt`.
    public static func screenRequest(_ screen: String) -> PermissionRequest? {
        guard let box = screenBox(screen), let id = screenPrompt(screen) else { return nil }
        return PermissionRequest(title: box.header, command: box.command, toolName: box.tool, toolUseId: id, state: .pending)
    }

    public enum Outcome: Sendable, Hashable {
        /// Send the approval card's input: `HerdrClient.respond(to:allow:)`.
        case send(allow: Bool)
        /// Send nothing; open the tab.
        case open
    }

    /// `now` is read after the action arrives (nil: the pane is gone). Anything but the same prompt still on screen opens the tab.
    public static func outcome(actionIdentifier: String, boundPrompt: String?, now: PaneState?, writes: Bool) -> Outcome {
        guard let action = Action(rawValue: actionIdentifier), let boundPrompt, let now,
              promptIDs(now, writes: writes).contains(boundPrompt) else { return .open }
        return .send(allow: action.allows)
    }
}

extension HerdrClient {
    /// Read-only: the pane's state for `ApprovalNotice`, with its visible screen. Nil when the screen cannot be read.
    public func approvalState(paneId: String, agentKind: String, blocked: Bool, pendingToolUseId: String?) async -> ApprovalNotice.PaneState? {
        guard let screen = try? await visibleText(paneId: paneId) else { return nil }
        return .init(agentKind: agentKind, blocked: blocked, pendingToolUseId: pendingToolUseId, screen: screen)
    }
}
