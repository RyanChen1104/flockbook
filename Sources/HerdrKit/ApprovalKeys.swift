import Foundation

/// Keystrokes for Claude Code's permission prompt ("Do you want to proceed?").
///
/// Verified 2026-10-09 against Claude Code 2.1.294 in session `c9-input-test`, manual permission mode, Bash tool:
/// - Prompt lists `1. Yes`, `2. Yes, and always allow…`, `3. Yes, and switch to auto mode`, `4. No`.
/// - `1` (typed, no Enter) approves once. The command ran.
/// - `Escape` denies. The command did not run.
/// - Do NOT use Enter blindly: the folder-trust dialog highlights "No, exit" by default.
/// The number of options changes with the prompt type, so deny uses Escape, never a number.
public enum ApprovalKeys {
    public static let allowOnce = "1"
    public static let deny = "Escape"
}

extension HerdrClient {
    /// Answer a permission prompt in `paneId`. Call only when the agent is `blocked` on a prompt.
    public func respond(to paneId: String, allow: Bool) async throws {
        if allow { _ = try await rawRequest(method: "pane.send_text", params: ["pane_id": paneId, "text": ApprovalKeys.allowOnce]) }
        else { try await sendNamedKeys([ApprovalKeys.deny], to: paneId) }
    }
}
