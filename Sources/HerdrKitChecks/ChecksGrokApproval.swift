import Foundation
@testable import HerdrKit

// Grok Build's permission prompt: its log has no prompt event (only the open call), so the card comes from the screen.
@MainActor func checksGrokApproval() async throws {
    // The prompt as Grok Build 1.0.67 draws it (shape captured live; text synthetic). `focus`: the row with (●).
    func prompt(_ command: String = "echo hi > out.txt", focus: Int = 2, reject: String = "No, reject (type to add feedback)") -> String {
        let rows = ["Yes, and don't ask again for anything (always-approve mode)", "Yes, proceed", reject, "Never allow: echo"]
        var l = ["  ❯ Write a file.", "", "  ◆ Write hi into out.txt… 3.0s", "", "  ┃", "  ┃  ›  Write hi into out.txt", "  ┃  │ \(command)",
                 "  ┃  ← → narrow scope", "  ┃"]
        for (i, r) in rows.enumerated() { l.append("  ┃  \(i + 1) (\(i + 1 == focus ? "●" : "○")) \(r)") }
        l += ["  ┃", "", "  1/4:select  │  Tab:next option  │  ←/→:scope  │  Ctrl+o:always-approve  │  Ctrl+c:cancel  │  Esc:scrollback"]
        return l.joined(separator: "\n")
    }
    let s = prompt()
    let box = ApprovalNotice.grokBox(s)
    check(box?.title == "Write hi into out.txt" && box?.command == "echo hi > out.txt" && box?.focus == 1, "grok approval: the prompt read from the screen")
    check(PermissionGate.screenShowsPrompt(s) && Hub.screenTakesKeys(s), "grok approval: a prompt on screen takes keys")
    let idle = "  ╭──────╮\n  │ ❯    │\n  ╰──────╯\n  Shift+Tab:mode  │  Ctrl+.:shortcuts"
    check(ApprovalNotice.grokBox(idle) == nil && !PermissionGate.screenShowsPrompt(idle), "grok approval: no prompt on the idle screen")
    let question = "  ┃\n  ┃  Which color?\n  ┃\n  ┃  1 (○) Red  Warm.\n  ┃  2 (○) Blue  Cool.\n  ┃  z (○) Type your answer here\n  ┃\n  ┃  [1/1] ↑/↓ navigate · ←/→ question · y copy  Enter:submit\n  ┃\n\n  Tab:next answer  │  Esc:scrollback  │  Shift+x:dismiss"
    check(ApprovalNotice.grokBox(question) == nil, "grok approval: a question picker is not a prompt")

    // The id: the prompt on screen, the same while the focus moves; the log's open call too when it is the same command.
    let st = { (screen: String, kind: String, blocked: Bool, logged: PermissionRequest?) in
        ApprovalNotice.PaneState(agentKind: kind, blocked: blocked, pendingToolUseId: logged?.toolUseId, screen: screen, pendingTool: logged?.toolName, pendingCommand: logged?.command)
    }
    let onScreen = ApprovalNotice.promptIDs(st(s, "grok", true, nil), writes: true)
    check(onScreen.count == 1 && onScreen[0].hasPrefix("screen-"), "grok approval: the screen's id \(onScreen)")
    check(ApprovalNotice.promptIDs(st(prompt(focus: 3), "grok", true, nil), writes: true) == onScreen, "grok approval: the focus moving keeps the id")
    check(ApprovalNotice.promptIDs(st(prompt("echo b > out.txt"), "grok", true, nil), writes: true) != onScreen, "grok approval: another command, another id")
    let call = PermissionRequest(title: "Bash", command: "echo hi > out.txt", toolName: "Bash", toolUseId: "call-1")
    check(ApprovalNotice.promptIDs(st(s, "grok", true, call), writes: true) == ["call-1"] + onScreen, "grok approval: the log's open call is the prompt")
    var other = call; other.command = "ls"
    check(ApprovalNotice.promptIDs(st(s, "grok", true, other), writes: true) == onScreen, "grok approval: a lagging log call does not name the prompt")
    check(ApprovalNotice.promptIDs(st(s, "grok", false, nil), writes: true).isEmpty && ApprovalNotice.promptIDs(st(s, "grok", true, nil), writes: false).isEmpty
          && ApprovalNotice.promptIDs(st(s, "claude", true, nil), writes: true).isEmpty, "grok approval: blocked grok with input on only")
    let r = ApprovalNotice.screenRequest(s, agent: "grok")
    check(r?.toolUseId == onScreen.first && r?.command == "echo hi > out.txt" && r?.toolName == "Bash" && ApprovalNotice.screenRequest(s) == nil, "grok approval: the card from the screen")
    check(Hub.openApproval(st(s, "grok", true, nil), logged: nil)?.command == "echo hi > out.txt", "grok approval: the hub's card")

    // Keys (live): Enter answers the row with focus. Allow: only from "Yes, proceed". Deny: Down from it to "No, reject"
    // right below, then Enter. The always-approve and never-allow rows are never chosen; any other focus sends nothing.
    check(ApprovalNotice.grokKey(s, allow: true) == "Enter" && ApprovalNotice.grokKey(prompt(focus: 3), allow: true) == nil
          && ApprovalNotice.grokKey(prompt(focus: 1), allow: true) == nil, "grok approval keys: allow from Yes, proceed only")
    check(ApprovalNotice.grokKey(s, allow: false) == "Down" && ApprovalNotice.grokKey(prompt(focus: 3), allow: false) == "Enter"
          && ApprovalNotice.grokKey(prompt(focus: 4), allow: false) == nil && ApprovalNotice.grokKey(prompt(focus: 1), allow: false) == nil, "grok approval keys: deny via No, reject")
    check(ApprovalNotice.grokKey(prompt(focus: 3, reject: "No, reject: too risky"), allow: false) == nil, "grok approval keys: typed feedback is the user's: no key")
}
