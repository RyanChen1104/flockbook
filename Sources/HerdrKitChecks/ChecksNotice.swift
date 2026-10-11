import Foundation
@testable import HerdrKit

// Allow / Deny on the blocked notification: which notifications get buttons, the stale-prompt guard, and that an action
// sends the same input as the in-app approval card (HerdrClient.respond).
@MainActor func checksApprovalNotice() async throws {
    typealias N = ApprovalNotice
    let prompt = """
     Bash command
       npm run build
     Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and don't ask again for npm run build commands in /repo
       3. No, and tell Claude what to do differently (esc)
    """
    let picker = """
     ←  ☐ Deploy  ✔ Submit  →
     Do you want to deploy now?
     ❯ 1. Yes
       2. No
       3. Type something.
     ────────────────
       Chat about this
    """
    let blocked = N.PaneState(agentKind: "claude", blocked: true, pendingToolUseId: "toolu_1", screen: prompt)

    // Which notifications get buttons.
    check(N.prompt(blocked, writes: true) == "toolu_1", "notice: Claude permission prompt gets buttons, bound to the pending call")
    check(N.prompt(blocked, writes: false) == nil, "notice: input off -> no buttons")
    var s = blocked; s.screen = picker; s.pendingToolUseId = nil
    check(N.prompt(s, writes: true) == nil, "notice: question picker -> no buttons")
    s.pendingToolUseId = "toolu_1"
    check(N.prompt(s, writes: true) == nil, "notice: question picker with an open call -> no buttons")
    s = blocked; s.screen = "Running tests…"
    check(N.prompt(s, writes: true) == nil, "notice: no prompt on screen (tool running) -> no buttons")
    s = blocked; s.pendingToolUseId = nil
    check(N.prompt(s, writes: true) == nil, "notice: no pending tool call in the log -> no buttons")
    s = blocked; s.blocked = false
    check(N.prompt(s, writes: true) == nil, "notice: agent not blocked -> no buttons")
    s = blocked; s.agentKind = "codex"
    check(N.prompt(s, writes: true) == nil, "notice: approval keys are verified for Claude only -> no buttons for Codex")

    // Action -> outcome, with the stale-prompt guard.
    check(N.Action.allow.allows && !N.Action.deny.allows, "notice: allow allows, deny denies")
    check(N.outcome(actionIdentifier: N.Action.allow.rawValue, boundPrompt: "toolu_1", now: blocked, writes: true) == .send(allow: true), "notice: Allow on the same prompt sends allow")
    check(N.outcome(actionIdentifier: N.Action.deny.rawValue, boundPrompt: "toolu_1", now: blocked, writes: true) == .send(allow: false), "notice: Deny on the same prompt sends deny")
    check(N.outcome(actionIdentifier: N.Action.allow.rawValue, boundPrompt: "toolu_0", now: blocked, writes: true) == .open, "notice: another prompt now -> open, send nothing")
    s = blocked; s.screen = "Running tests…"
    check(N.outcome(actionIdentifier: N.Action.allow.rawValue, boundPrompt: "toolu_1", now: s, writes: true) == .open, "notice: prompt gone from screen -> open")
    s = blocked; s.blocked = false
    check(N.outcome(actionIdentifier: N.Action.deny.rawValue, boundPrompt: "toolu_1", now: s, writes: true) == .open, "notice: agent no longer blocked -> open")
    check(N.outcome(actionIdentifier: N.Action.allow.rawValue, boundPrompt: "toolu_1", now: nil, writes: true) == .open, "notice: pane gone -> open")
    check(N.outcome(actionIdentifier: N.Action.allow.rawValue, boundPrompt: "toolu_1", now: blocked, writes: false) == .open, "notice: input turned off since -> open")
    check(N.outcome(actionIdentifier: N.Action.allow.rawValue, boundPrompt: nil, now: blocked, writes: true) == .open, "notice: notification without a bound prompt -> open")
    check(N.outcome(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", boundPrompt: "toolu_1", now: blocked, writes: true) == .open, "notice: plain click -> open")

    // Wire level against a fake herdr: reading the state sends nothing; the send is the card's own input.
    do {
        let fake = FakeHerdr(path: NSTemporaryDirectory() + "hkntc-\(getpid()).sock")
        try fake.start()
        defer { fake.kill() }
        let client = HerdrClient(session: HerdrSession(name: "fake", socketPath: fake.path))
        fake.screen = prompt
        let st = await client.approvalState(paneId: "w1:p1", agentKind: "claude", blocked: true, pendingToolUseId: "toolu_1")
        check(st?.screen.contains("Do you want to proceed?") == true, "notice: state read from the pane's visible screen")
        check(fake.requests.allSatisfy { $0.method == "pane.read" } && !fake.requests.isEmpty, "notice: reading the state only reads (\(fake.requests.map(\.method)))")
        let n0 = fake.requests.count
        guard case .send(let allow) = N.outcome(actionIdentifier: N.Action.allow.rawValue, boundPrompt: "toolu_1", now: st, writes: true) else {
            check(false, "notice: fresh state allows the send"); return
        }
        try await client.respond(to: "w1:p1", allow: allow)
        let sent = fake.requests.dropFirst(n0)
        check(sent.count == 1 && sent.first?.method == "pane.send_text" && sent.first?.params["text"] as? String == ApprovalKeys.allowOnce,
              "notice: Allow sends the card's allow input (text \"1\", no Enter)")
        let n1 = fake.requests.count
        try await client.respond(to: "w1:p1", allow: N.Action.deny.allows)
        let denied = fake.requests.dropFirst(n1)
        check(denied.count == 1 && denied.first?.method == "pane.send_keys" && denied.first?.params["keys"] as? [String] == [ApprovalKeys.deny],
              "notice: Deny sends the card's deny input (Escape)")
        fake.screen = "Running tests…"
        let stale = await client.approvalState(paneId: "w1:p1", agentKind: "claude", blocked: true, pendingToolUseId: "toolu_1")
        check(N.outcome(actionIdentifier: N.Action.allow.rawValue, boundPrompt: "toolu_1", now: stale, writes: true) == .open, "notice: screen changed after posting -> open")
    }
}
