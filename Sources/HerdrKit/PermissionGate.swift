import Foundation

/// Permission-prompt detection. The kit reports unanswered tool calls (`PermissionRequest.state == .pending`);
/// only the screen tells a prompt from a running tool.
public enum PermissionGate {
    /// Text Claude Code draws on its permission prompt.
    public static let promptMarker = "Do you want"

    public static func screenShowsPrompt(_ screenText: String) -> Bool {
        screenText.contains(promptMarker)
    }
}

extension HerdrClient {
    /// Read-only: does the pane's visible screen show a permission prompt right now?
    /// Show the Approval card + Allow/Deny only when true; otherwise show a "Running <tool>…" chip.
    /// Send approval keys only when true.
    public func checkPrompt(paneId: String) async -> Bool {
        guard let data = try? await rawRequest(method: "pane.read", params: ["pane_id": paneId, "source": "visible", "format": "text", "lines": 40]),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let read = (o["result"] as? [String: Any])?["read"] as? [String: Any],
              let text = read["text"] as? String else { return false }
        return PermissionGate.screenShowsPrompt(text)
    }
}
