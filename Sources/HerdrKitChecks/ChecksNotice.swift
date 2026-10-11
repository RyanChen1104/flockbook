import Foundation
@testable import HerdrKit

// Allow / Deny on the blocked notification: which notifications get buttons, the stale-prompt guard, and that an action
// sends the same input as the in-app approval card (HerdrClient.respond).
@MainActor func checksApprovalNotice() async throws {
    typealias N = ApprovalNotice
    let prompt = """
    ────────────────────────────────────────
     Bash command
     Tip: auto mode handles these prompts for you — choose "switch to auto mode" below
     Build the web app
    ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
     npm run build
    ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
     Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and always allow access to /repo from this project
       3. Yes, and switch to auto mode · auto mode handles these prompts for you
       4. No

     Esc to cancel · Tab to amend
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
    let blocked = N.PaneState(agentKind: "claude", blocked: true, pendingToolUseId: "toolu_1", screen: "old output\n" + prompt,
                              pendingTool: "Bash", pendingCommand: "npm run build")

    // Which notifications get buttons.
    check(N.prompt(blocked, writes: true) == "toolu_1", "notice: Claude permission prompt gets buttons, bound to the pending call")
    check(N.prompt(blocked, writes: false) == nil, "notice: input off -> no buttons")
    var s = blocked; s.screen = picker; s.pendingToolUseId = nil
    check(N.prompt(s, writes: true) == nil, "notice: question picker -> no buttons")
    s.pendingToolUseId = "toolu_1"
    check(N.prompt(s, writes: true) == nil, "notice: question picker with an open call -> no buttons")
    s = blocked; s.screen = "Running tests…"
    check(N.prompt(s, writes: true) == nil, "notice: no prompt on screen (tool running) -> no buttons")
    // No transcript (or the log lags the screen): bind to the prompt on screen instead.
    var nolog = blocked; nolog.pendingToolUseId = nil
    let fp = N.prompt(nolog, writes: true)
    check(fp != nil && fp != "toolu_1" && fp == N.screenPrompt(prompt), "notice: no pending call in the log -> buttons bound to the prompt on screen")
    check(N.screenPrompt(prompt + "\n") == N.screenPrompt(prompt) && N.screenPrompt("Running tests…") == nil, "notice: screen prompt id is stable, nil without a prompt")
    let other = prompt.replacingOccurrences(of: "npm run build", with: "rm -rf build")
    check(N.screenPrompt(other) != N.screenPrompt(prompt), "notice: another command -> another screen prompt id")
    check(N.screenPrompt("old output\n" + prompt) == N.screenPrompt(prompt), "notice: text above the prompt box does not change the id")
    check(N.outcome(actionIdentifier: N.Action.allow.rawValue, boundPrompt: fp, now: nolog, writes: true) == .send(allow: true), "notice: screen-bound Allow, same prompt -> send")
    check(N.outcome(actionIdentifier: N.Action.allow.rawValue, boundPrompt: fp, now: blocked, writes: true) == .send(allow: true), "notice: screen-bound, log caught up with the same prompt -> send")
    var otherNow = nolog; otherNow.screen = other
    check(N.outcome(actionIdentifier: N.Action.allow.rawValue, boundPrompt: fp, now: otherNow, writes: true) == .open, "notice: screen-bound, another prompt now -> open")
    s = blocked; s.blocked = false
    check(N.prompt(s, writes: true) == nil, "notice: agent not blocked -> no buttons")
    s = blocked; s.agentKind = "codex"
    check(N.prompt(s, writes: true) == nil, "notice: approval keys are verified for Claude only -> no buttons for Codex")

    // The prompt box read from the screen: the card's request when the log has none.
    let req = N.screenRequest(prompt)
    check(req?.title == "Bash command" && req?.toolName == "Bash" && req?.command == "npm run build" && req?.state == .pending,
          "notice: screen request has the tool and the command (\(String(describing: req)))")
    check(req?.toolUseId == N.screenPrompt(prompt), "notice: screen request id = screen prompt id")
    check(N.screenRequest("Running tests…") == nil && N.screenRequest(picker) == nil, "notice: no screen request without a permission prompt")
    let edit = prompt.replacingOccurrences(of: " Bash command", with: " Edit file")
    check(N.screenPrompt(edit) != N.screenPrompt(prompt), "notice: screen id includes the tool name")
    let opts = prompt.replacingOccurrences(of: "access to /repo", with: "access to /other")
    check(N.screenPrompt(opts) != N.screenPrompt(prompt), "notice: screen id includes the whole box (options too)")
    let moved = prompt.replacingOccurrences(of: " ❯ 1. Yes\n   2.", with: "   1. Yes\n ❯ 2.")
    check(N.screenPrompt(moved) == N.screenPrompt(prompt), "notice: the option cursor does not change the screen id")

    // A workflow's call (its transcript is not the main log): 2 options, a danger note and a countdown that changes every second.
    func workflowPrompt(_ left: String) -> String {
        """
        ⏺ Bash(cleanup)
        ────────────────────────────────────────
         Bash command · from the "build-r1-t2" workflow
         Remove probe files
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
         cd /work/app &&
           rm -f /tmp_probe_check.json &&
           ls
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
         Dangerous rm operation on critical path: /tmp_probe_check.json
         ⚠ Claude Code will automatically deny this request in \(left), to avoid blocking progress on an unattended session

         Do you want to proceed?
         ❯ 1. Yes
           2. No

         Esc to cancel · Tab to amend
        """
    }
    let wf = workflowPrompt("1:23"), wfLater = workflowPrompt("1:22")
    let wfReq = N.screenRequest(wf)
    check(wfReq?.toolName == "Bash" && wfReq?.title.hasPrefix("Bash command") == true && wfReq?.command == "cd /work/app &&\nrm -f /tmp_probe_check.json &&\nls",
          "notice: workflow prompt -> card request (\(String(describing: wfReq)))")
    var wfState = N.PaneState(agentKind: "claude", blocked: true, pendingToolUseId: nil, screen: wf)
    check(N.prompt(wfState, writes: true) == N.screenPrompt(wf) && N.screenPrompt(wf) != nil, "notice: workflow prompt without a log row -> buttons")
    check(N.screenPrompt(wf) == N.screenPrompt(wfLater), "notice: the auto-deny countdown is not part of the screen id")
    wfState.screen = wfLater
    check(N.outcome(actionIdentifier: N.Action.allow.rawValue, boundPrompt: N.screenPrompt(wf), now: wfState, writes: true) == .send(allow: true),
          "notice: Allow a second later (countdown moved) -> send")
    check(N.screenPrompt(wf.replacingOccurrences(of: "rm -f", with: "rm -rf")) != N.screenPrompt(wf), "notice: another command in the workflow prompt -> another id")
    // Two options: "1" is still Yes and Escape still denies (no option number).
    check(wf.contains("1. Yes") && ApprovalKeys.allowOnce == "1" && ApprovalKeys.deny == "Escape", "notice: 2-option prompt keeps allow = 1, deny = Escape")

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
        let st = await client.approvalState(paneId: "w1:p1", agentKind: "claude", blocked: true,
                                               pending: PermissionRequest(title: "Bash", command: "npm run build", toolName: "Bash", toolUseId: "toolu_1"))
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
        let stale = await client.approvalState(paneId: "w1:p1", agentKind: "claude", blocked: true,
                                               pending: PermissionRequest(title: "Bash", command: "npm run build", toolName: "Bash", toolUseId: "toolu_1"))
        check(N.outcome(actionIdentifier: N.Action.allow.rawValue, boundPrompt: "toolu_1", now: stale, writes: true) == .open, "notice: screen changed after posting -> open")
    }
}
