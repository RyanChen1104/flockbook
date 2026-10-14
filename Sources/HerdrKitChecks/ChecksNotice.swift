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

    // The notification's text: an approval says what it approves; other notices stay as they were.
    do {
        let plain = N.text(agent: "claude", workspace: "web", tab: "build", request: nil)
        check(plain == N.Text(title: "claude", subtitle: "", body: "Needs you · web · build"), "notice text: no approval -> as before (\(plain))")
        let bash = N.text(agent: "claude", workspace: "web", tab: "build",
                          request: PermissionRequest(title: "Bash command", command: "  npm run build  ", toolName: "Bash", toolUseId: "toolu_1"))
        check(bash.title == "claude wants to run Bash", "notice text: title names the agent and the tool (\(bash.title))")
        check(bash.subtitle == "web · build", "notice text: workspace and tab in the subtitle (\(bash.subtitle))")
        check(bash.body == "npm run build", "notice text: body is the command, trimmed (\(bash.body))")
        let long = N.text(agent: "claude", workspace: "web", tab: "build", request: PermissionRequest(
            title: "Bash command", command: "\n  cd /work\n\n  rm -rf build\n  npm ci\n", toolName: "Bash"))
        check(long.body == "cd /work\nrm -rf build …", "notice text: first two lines, then … (\(long.body.debugDescription))")
        let wide = N.text(agent: "claude", workspace: "w", tab: "t", request: PermissionRequest(title: "x", command: String(repeating: "a", count: 300), toolName: "Bash"))
        check(wide.body.count <= 121 && wide.body.hasSuffix("…"), "notice text: a long line is cut (\(wide.body.count))")
        let noCommand = N.text(agent: "", workspace: "web", tab: "build", request: PermissionRequest(title: "Fetch https://example.com", command: "", toolName: "WebFetch"))
        check(noCommand.title == "build wants to run WebFetch" && noCommand.body == "Fetch https://example.com",
              "notice text: no agent name -> tab label; no command -> the request title (\(noCommand))")
        let noTool = N.text(agent: "claude", workspace: "web", tab: "build", request: PermissionRequest(title: "", command: "", toolName: ""))
        check(noTool.title == "claude wants to run a tool" && noTool.body == "Needs you", "notice text: empty request still reads (\(noTool))")
        let ctrl = N.text(agent: "claude", workspace: "w", tab: "t", request: PermissionRequest(title: "x", command: "echo \u{1b}[31mred", toolName: "Bash"))
        check(ctrl.body == "echo red", "notice text: colour codes and control characters removed (\(ctrl.body.debugDescription))")
    }

    // Claude 2.1.296 draws a "│" gutter on a wrapped command and breaks it mid-word (seen live).
    do {
        let rule = String(repeating: "╌", count: 40)
        func wrapped(_ l1: String, _ l2: String) -> String {
            "────────────────────────────────────────\n Bash command\n Tip: auto mode handles these prompts for you\n Create the file\n\(rule)\n"
                + " │ \(l1)\n │ \(l2)\n\(rule)\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n Esc to cancel · Tab to amend"
        }
        let midWord = wrapped("touch /work/project/build/output/scrat", "chpad/notes.txt")
        let r = N.screenRequest(midWord)
        check(r?.command == "touch /work/project/build/output/scrat\nchpad/notes.txt", "notice wrap: gutter removed from the command (\(r?.command.debugDescription ?? "nil"))")
        func st(_ screen: String, _ command: String) -> N.PaneState {
            N.PaneState(agentKind: "claude", blocked: true, pendingToolUseId: "toolu_9", screen: screen, pendingTool: "Bash", pendingCommand: command)
        }
        check(N.prompt(st(midWord, "touch /work/project/build/output/scratchpad/notes.txt"), writes: true) == "toolu_9",
              "notice wrap: the log's call matches a box wrapped mid-word")
        let atSpace = wrapped("npm run build --workspace", "web")
        check(N.prompt(st(atSpace, "npm run build --workspace web"), writes: true) == "toolu_9", "notice wrap: the log's call matches a box wrapped at a space")
        check(N.prompt(st(midWord, "touch /work/project/build/output/scratchpad/other.txt"), writes: true) == N.screenPrompt(midWord),
              "notice wrap: another command still binds the screen id")
        check(N.prompt(st(midWord, "touch /work/project/build/output/scrat"), writes: true) == N.screenPrompt(midWord),
              "notice wrap: a log command that is only the first line does not match")
    }

    // P3-15: one card with live buttons per pane, bound to the id the tab's card and the notification use.
    do {
        // The older Claude Code layout: the description under the command, no dashed rules. The command read from the
        // box then holds the description too, and the log's call never matches it.
        let older = """
        ────────────────────────────────────────
         Bash command

           npm run build
           Build the web app

         Do you want to proceed?
         ❯ 1. Yes
           2. No

         Esc to cancel · Tab to amend
        """
        let logged = PermissionRequest(title: "Bash", command: "npm run build", toolName: "Bash", toolUseId: "toolu_7")
        let onScreen = N.screenRequest(older)
        let card = N.cardRequest(logged: logged, onScreen: onScreen)
        check(card?.toolUseId == N.screenPrompt(older), "p3-15: older layout -> the card binds the screen id")
        check(N.cardPlace(pending: logged, card: card) == .composer(card!),
              "p3-15: the log's call is not the card -> the screen card in the composer, no buttons on the log's call")
        let now = N.PaneState(agentKind: "claude", blocked: true, pendingToolUseId: "toolu_7", screen: older, pendingTool: "Bash", pendingCommand: "npm run build")
        if case .composer(let r) = N.cardPlace(pending: logged, card: card) {
            check(N.outcome(actionIdentifier: N.Action.allow.rawValue, boundPrompt: r.toolUseId, now: now, writes: true) == .send(allow: true),
                  "p3-15: the composer card's id passes the re-check before the keys")
        }
        check(N.outcome(actionIdentifier: N.Action.allow.rawValue, boundPrompt: "toolu_7", now: now, writes: true) == .open,
              "p3-15: the log's id would send nothing (why it gets no buttons)")
        // Current layout: the log's call is the box -> the card stays in the conversation, bound to the log's id.
        let current = N.cardRequest(logged: logged, onScreen: N.screenRequest(prompt))
        check(N.cardPlace(pending: logged, card: current) == .conversation(toolUseId: "toolu_7"), "p3-15: log matches the box -> the conversation card")
        // No log call (no transcript): the screen card in the composer. No prompt at all: no card.
        check(N.cardPlace(pending: nil, card: onScreen) == .composer(onScreen!), "p3-15: no log call -> the screen card in the composer")
        check(N.cardPlace(pending: logged, card: nil) == .none && N.cardPlace(pending: nil, card: nil) == .none, "p3-15: no card -> none")
    }
}
