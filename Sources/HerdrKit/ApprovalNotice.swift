import Foundation

/// Allow / Deny buttons on the "needs you" system notification for a permission prompt.
///
/// Buttons only where the in-app approval card would offer Allow / Deny: input is on, the agent is blocked, its log
/// ends with a pending tool call and the screen shows the permission prompt (`PermissionGate`). Only Claude Code:
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

    /// The prompt a notification's buttons answer (the pending tool call's id). Nil: no buttons.
    public static func prompt(_ s: PaneState, writes: Bool) -> String? {
        guard writes, s.blocked, s.agentKind == "claude",
              let id = s.pendingToolUseId, !id.isEmpty,
              PermissionGate.screenShowsPrompt(s.screen),
              QuestionAdapter.claudeScreen(s.screen) == nil else { return nil }
        return id
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
              prompt(now, writes: writes) == boundPrompt else { return .open }
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
