import Foundation
@testable import HerdrKit

/// A hub backend in memory: what the app gives the hub, and a record of every input the hub asked for.
@MainActor final class FakeHubBackend: HubBackend {
    var hubName = "test hub"
    var hubVersion = "0.0.1"
    var sessionName: String? = "demo"
    var workspaces: [Workspace]
    var writesEnabled = true
    var items: [String: [ConversationItem]] = [:]
    var screens: [String: String] = [:]
    /// Older items `loadEarlier` puts in front, once.
    var earlier: [String: [ConversationItem]] = [:]
    var sendOK = true
    private(set) var sent: [String] = []
    private(set) var approved: [String] = []
    private(set) var answered: [String] = []
    var inputs: Int { sent.count + approved.count + answered.count }

    init(workspaces: [Workspace]) { self.workspaces = workspaces }
    var pushKey: String? = "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
    let pushes = MemoryPushStore()
    func pushSubscribe(_ s: PushSubscription) -> Bool { pushes.add(s) }
    func pushUnsubscribe(device: String, endpoint: String) { pushes.remove(device: device, endpoint: endpoint) }
    func pushSubscribed(device: String) -> Bool { pushes.all.contains { $0.device == device } }

    func conversation(session: String) -> [ConversationItem] { items[session] ?? [] }
    func hasEarlier(session: String) -> Bool { earlier[session] != nil }
    func loadEarlier(session: String) async -> Bool {
        if let e = earlier.removeValue(forKey: session) { items[session] = e + (items[session] ?? []) }
        return false
    }
    /// Called on each screen read (a test can change the world mid-check).
    var onScreen: (() -> Void)?
    func screen(pane: String) async -> String? { onScreen?(); return screens[pane] }
    var sendResult = HubSendResult.sent
    var imageDirectory: URL?
    /// The image files of each send that had some.
    var sentImages: [[URL]] = []
    /// Called while the backend works (between its checks and the keys): a downgrade there must stop the keys.
    var beforeKeys: (() -> Void)?
    /// What `allowed()` said right before the keys, per call.
    private(set) var allowedAtKeys: [Bool] = []
    private(set) var sentAgents: [String?] = []
    /// How long the next send takes (once; the web test switches agents meanwhile).
    var sendDelay: Duration = .zero
    func send(pane: String, text: String, images: [URL], agent: Agent, allowed: @escaping @MainActor @Sendable () -> Bool) async -> HubSendResult {
        beforeKeys?()
        let delay = sendDelay
        sendDelay = .zero
        if delay > .zero { try? await Task.sleep(for: delay) }
        allowedAtKeys.append(allowed())
        guard allowed() else { return .failed }
        sentAgents.append(agent.sessionId)
        sent.append("\(pane) \(text)")
        if !images.isEmpty { sentImages.append(images) }
        return sendOK ? sendResult : .failed
    }
    var approveOK = true
    func approve(pane: String, prompt: String, allow: Bool, agent: Agent, allowed: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        beforeKeys?()
        allowedAtKeys.append(allowed())
        guard allowed() else { return false }
        approved.append("\(pane) \(prompt) \(allow)"); return approveOK
    }
    /// Claude Code's queue per session, as a log would have it.
    var queuedLogs: [String: ClaudeQueueLog] = [:]
    func queuedLog(session: String) -> ClaudeQueueLog { queuedLogs[session] ?? [] }
    var pulledTexts = MemoryPulledStore()
    var pullOutcome = QueuePull.Outcome.refused("not set")
    /// "pane session" per pull.
    private(set) var pulls: [String] = []
    /// How long a pull takes (the web test switches agents meanwhile).
    var pullDelay: Duration = .zero
    /// What `keep` answered for the last pull with text (nil: not asked).
    private(set) var kept: Bool?
    /// The kept text's note right after `keep` (while the pull runs).
    private(set) var keptNote: String?
    func pullQueued(pane: String, agent: Agent, log: ClaudeQueueLog, keep: @escaping @MainActor @Sendable (String) -> Bool,
                    allowed: @escaping @MainActor @Sendable () -> Bool) async -> QueuePull.Outcome {
        beforeKeys?()
        allowedAtKeys.append(allowed())
        guard allowed() else { return .refused("Input is off. Nothing was sent.") }
        pulls.append("\(pane) \(agent.sessionId ?? "")")
        if pullDelay > .zero { try? await Task.sleep(for: pullDelay) }
        kept = pullOutcome.text.map(keep)
        keptNote = pulledTexts.all.last?.note
        return pullOutcome
    }
    /// The hook's newest call per agent session.
    var hooked: [String: QuestionRequest] = [:]
    func hookedQuestion(session: String) -> QuestionRequest? { hooked[session] }
    func answer(pane: String, question: QuestionRequest, answers: [QuestionAnswer], agent: Agent, allowed: @escaping @MainActor @Sendable () -> Bool) async throws {
        beforeKeys?()
        allowedAtKeys.append(allowed())
        guard allowed() else { throw QuestionAdapter.Failure.unsupported("input is off") }
        answered.append("\(pane) \(question.toolUseId) \(answers.map(\.picks))")
    }
}

// HubSession: the protocol logic of one connection, without a network.
@MainActor func checksHubSession() async throws {
    func ws(_ status: AgentStatus, kind: String = "claude") -> [Workspace] {
        let a = Agent(name: kind, kind: kind, status: status, sessionId: "s1", title: "Fix the build")
        let shell = Pane(id: "w1:p2", terminalId: "term_2", cwd: "/work", agent: nil)
        return [Workspace(id: "w1", label: "web", tabs: [Tab(id: "w1:t1", label: "build", number: 1,
                          panes: [Pane(id: "w1:p1", terminalId: "term_1", cwd: "/work", agent: a), shell], status: status)])]
    }
    let prompt = """
    ────────────────────────────────────────
     Bash command
     Build it
    ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
     npm run build
    ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
     Do you want to proceed?
     ❯ 1. Yes
       2. No

     Esc to cancel · Tab to amend
    """
    let picker = """
     ←  ☐ Target  ✔ Submit  →

    Which target?

    ❯ 1. Staging
      2. Production
      3. Type something.
    ──────────────────────────
      Chat about this
    """
    func item(_ i: Int) -> ConversationItem { ConversationItem(id: "i\(i)", kind: .assistantText("message \(i)")) }
    func msg(_ json: String) -> Data { Data(json.utf8) }
    func types(_ ms: [HubMessage]) -> [String] { ms.map(\.type) }
    func reply(_ ms: [HubMessage]) -> HubReply? { ms.last.flatMap { if case .reply(let r) = $0 { r } else { nil } } }
    func code(_ ms: [HubMessage]) -> HubError.Code? { reply(ms)?.error?.code }

    let devices = MemoryDeviceStore()
    devices.add(token: "tok-read", device: HubDevice(id: "d-read", name: "Phone", level: .read))
    devices.add(token: "tok-input", device: HubDevice(id: "d-input", name: "Tablet", level: .input))
    check(!devices.hashes.contains("tok-read") && devices.hashes.contains(HubToken.hash("tok-read")) && HubToken.hash("tok-read").count == 64,
          "hub session: device tokens are stored as SHA-256 hashes")

    func session(_ b: FakeHubBackend, token: String = "tok-input") async -> (HubSession, [HubMessage]) {
        let s = HubSession(backend: b, devices: devices)
        let out = await s.receive(msg(#"{"v":1,"type":"hello","id":"h","token":"\#(token)","client":"test","clientVersion":"1"}"#))
        return (s, out)
    }

    // Auth.
    do {
        let b = FakeHubBackend(workspaces: ws(.idle))
        let s = HubSession(backend: b, devices: devices)
        let out = await s.receive(msg(#"{"v":1,"type":"watch","id":"c1","pane":"w1:p1"}"#))
        check(code(out) == .unauthorized && reply(out)?.re == "c1" && s.closed, "hub session: a message before hello -> unauthorized, closed")
        let (bad, badOut) = await session(b, token: "nope")
        check(code(badOut) == .unauthorized && bad.closed, "hub session: unknown token -> unauthorized, closed")
        let (good, goodOut) = await session(b, token: "tok-read")
        check(types(goodOut) == ["welcome", "snapshot", "reply"] && reply(goodOut)?.ok == true && !good.closed, "hub session: hello -> welcome, snapshot, reply")
        if case .welcome(let w) = goodOut.first { check(w.level == .read && w.session == "demo" && w.hub == "test hub", "hub session: welcome has the device level") }
    }

    // Versions and bad messages.
    do {
        let b = FakeHubBackend(workspaces: ws(.idle))
        let (s, _) = await session(b)
        let k = await s.receive(msg(#"{"v":1,"type":"keys","id":"c9","pane":"w1:p1","keys":["Enter"]}"#))
        check(code(k) == .badRequest && reply(k)?.re == "c9" && !s.closed && b.inputs == 0, "hub session: raw keys -> badRequest, nothing sent")
        let junk = await s.receive(msg("not json"))
        check(code(junk) == .badRequest && !s.closed, "hub session: malformed -> badRequest")
        let v2 = await s.receive(msg(#"{"v":2,"type":"ping","id":"c10"}"#))
        check(code(v2) == .unsupportedVersion && reply(v2)?.re == "c10" && s.closed, "hub session: v2 -> unsupportedVersion, closed")
        let after = await s.receive(msg(#"{"v":1,"type":"ping","id":"c11"}"#))
        check(after.isEmpty, "hub session: nothing after close")
        let (p, _) = await session(b)
        check(types(await p.receive(msg(#"{"v":1,"type":"ping","id":"c12"}"#))) == ["pong", "reply"], "hub session: ping -> pong, reply")
    }

    // Levels.
    do {
        let b = FakeHubBackend(workspaces: ws(.blocked)); b.screens["w1:p1"] = prompt
        let (r, _) = await session(b, token: "tok-read")
        let id = ApprovalNotice.screenPrompt(prompt) ?? ""
        check(code(await r.receive(msg(#"{"v":1,"type":"send","id":"c1","pane":"w1:p2","text":"hi"}"#))) == .readOnly, "hub session: read device cannot send")
        check(code(await r.receive(msg(#"{"v":1,"type":"approve","id":"c2","pane":"w1:p1","prompt":"\#(id)","allow":true}"#))) == .readOnly, "hub session: read device cannot approve")
        check(code(await r.receive(msg(#"{"v":1,"type":"answer","id":"c3","pane":"w1:p1","question":"x","answers":[]}"#))) == .readOnly, "hub session: read device cannot answer")
        b.writesEnabled = false
        let (i, _) = await session(b)
        check(code(await i.receive(msg(#"{"v":1,"type":"approve","id":"c4","pane":"w1:p1","prompt":"\#(id)","allow":true}"#))) == .readOnly, "hub session: Allow input off -> readOnly for every device")
        check(b.inputs == 0, "hub session: no input sent at read level")
    }

    // Watch and pushes.
    do {
        let b = FakeHubBackend(workspaces: ws(.working))
        b.items["s1"] = (0..<150).map(item); b.earlier["s1"] = (200..<220).map(item); b.screens["w1:p1"] = "working…"
        let (s, _) = await session(b)
        check(code(await s.receive(msg(#"{"v":1,"type":"watch","id":"c0","pane":"w9:p9"}"#))) == .notFound, "hub session: watch an unknown pane -> notFound")
        let w = await s.receive(msg(#"{"v":1,"type":"watch","id":"c1","pane":"w1:p1"}"#))
        check(types(w) == ["conversation", "screen", "prompt", "reply"], "hub session: watch -> conversation, screen, prompt, reply (\(types(w)))")
        if case .conversation(let c) = w.first {
            check(c.mode == .replace && c.items.count == 100 && c.items.first?.id == "i50" && c.hasEarlier && c.session == "s1", "hub session: watch sends the last 100 items")
        }
        check(await s.tick().isEmpty, "hub session: tick with no change pushes nothing")
        b.items["s1"]?.append(item(150))
        let t1 = await s.tick()
        if case .conversation(let c)? = t1.first { check(c.mode == .append && c.items.map(\.id) == ["i150"], "hub session: a new item -> append") } else { check(false, "hub session: append pushed (\(types(t1)))") }
        b.items["s1"]?[149] = ConversationItem(id: "i149", kind: .assistantText("message 149, edited"))
        let t2 = await s.tick()
        if case .conversation(let c)? = t2.first { check(c.mode == .append && c.items.map(\.id) == ["i149"], "hub session: a changed item is sent again by id") } else { check(false, "hub session: changed item pushed") }
        b.screens["w1:p1"] = "still working…"
        check(types(await s.tick()) == ["screen"], "hub session: screen change -> screen push")
        b.workspaces = ws(.done)
        check(types(await s.tick()) == ["snapshot"], "hub session: status change -> snapshot push")
        let e = await s.receive(msg(#"{"v":1,"type":"loadEarlier","id":"c2","session":"s1","before":"i50"}"#))
        if case .conversation(let c)? = e.first {
            check(c.mode == .prepend && c.items.first?.id == "i200" && c.items.last?.id == "i49" && c.items.count == 70 && !c.hasEarlier,
                  "hub session: loadEarlier prepends what is before, loading older log first (\(c.items.count) items)")
        } else { check(false, "hub session: loadEarlier pushed (\(types(e)))") }
        check(await s.tick().isEmpty, "hub session: no replace after a prepend")
        _ = await s.receive(msg(#"{"v":1,"type":"unwatch","id":"c3","pane":"w1:p1"}"#))
        b.items["s1"]?.append(item(151))
        check(await s.tick().isEmpty, "hub session: unwatch stops pushes")
    }

    // Approve: the same id as the notification; stale -> nothing sent.
    do {
        let b = FakeHubBackend(workspaces: ws(.blocked)); b.screens["w1:p1"] = prompt
        let (s, _) = await session(b)
        let w = await s.receive(msg(#"{"v":1,"type":"watch","id":"c1","pane":"w1:p1"}"#))
        let pushed: HubApproval? = w.compactMap { if case .prompt(let p) = $0 { p.approval } else { nil } }.first
        let state = ApprovalNotice.PaneState(agentKind: "claude", blocked: true, pendingToolUseId: nil, screen: prompt)
        check(pushed?.id == ApprovalNotice.prompt(state, writes: true) && pushed?.command == "npm run build", "hub session: prompt push has the ApprovalNotice id")
        let stale = await s.receive(msg(#"{"v":1,"type":"approve","id":"c2","pane":"w1:p1","prompt":"toolu_old","allow":true}"#))
        check(code(stale) == .stale && b.approved.isEmpty, "hub session: approve with another id -> stale, nothing sent")
        let ok = await s.receive(msg(#"{"v":1,"type":"approve","id":"c3","pane":"w1:p1","prompt":"\#(pushed?.id ?? "")","allow":false}"#))
        check(reply(ok)?.ok == true && b.approved == ["w1:p1 \(pushed?.id ?? "") false"], "hub session: approve with the open id -> the card's path (deny)")
        b.screens["w1:p1"] = "Running…"
        let gone = await s.receive(msg(#"{"v":1,"type":"approve","id":"c4","pane":"w1:p1","prompt":"\#(pushed?.id ?? "")","allow":true}"#))
        check(code(gone) == .stale && b.approved.count == 1, "hub session: prompt gone -> stale")
        check(code(await s.receive(msg(#"{"v":1,"type":"approve","id":"c5","pane":"w9:p9","prompt":"x","allow":true}"#))) == .notFound, "hub session: approve on an unknown pane -> notFound")
    }

    // Send: refused while a prompt is open.
    do {
        let b = FakeHubBackend(workspaces: ws(.blocked)); b.screens["w1:p1"] = prompt
        let (s, _) = await session(b)
        check(code(await s.receive(msg(#"{"v":1,"type":"send","id":"c1","pane":"w1:p1","text":"yes"}"#))) == .promptOpen && b.sent.isEmpty,
              "hub session: send during a permission prompt -> promptOpen, nothing sent")
        b.screens["w1:p1"] = picker
        check(code(await s.receive(msg(#"{"v":1,"type":"send","id":"c2","pane":"w1:p1","text":"1"}"#))) == .promptOpen && b.sent.isEmpty,
              "hub session: send during a question picker -> promptOpen")
        b.screens["w1:p1"] = "❯ "; b.workspaces = ws(.idle)
        let ok = await s.receive(msg(#"{"v":1,"type":"send","id":"c3","pane":"w1:p1","text":"Run the tests"}"#))
        check(reply(ok)?.ok == true && b.sent == ["w1:p1 Run the tests"], "hub session: send with no prompt -> sent")
        b.sendOK = false
        check(code(await s.receive(msg(#"{"v":1,"type":"send","id":"c4","pane":"w1:p1","text":"again"}"#))) == .failed, "hub session: herdr refused the send -> failed")
    }

    // Answer: only the open question's id.
    do {
        let b = FakeHubBackend(workspaces: ws(.blocked)); b.screens["w1:p1"] = picker
        let (s, _) = await session(b)
        let w = await s.receive(msg(#"{"v":1,"type":"watch","id":"c1","pane":"w1:p1"}"#))
        let q: HubQuestion? = w.compactMap { if case .prompt(let p) = $0 { p.question } else { nil } }.first
        check(q?.id.hasPrefix("screen-") == true && q?.questions.first?.text == "Which target?", "hub session: picker -> prompt push with the question")
        let stale = await s.receive(msg(#"{"v":1,"type":"answer","id":"c2","pane":"w1:p1","question":"screen-0","answers":[{"picks":[0]}]}"#))
        check(code(stale) == .stale && b.answered.isEmpty, "hub session: answer another question -> stale, nothing sent")
        // A question read only from the screen (Claude: its log has the call only after the answer) has no source
        // the screen cannot write: the phone shows it, the Mac answers it.
        check(q?.onMac == true, "hub session: a screen-read question is marked 'answer on the Mac'")
        let mac = await s.receive(msg(#"{"v":1,"type":"answer","id":"c3","pane":"w1:p1","question":"\#(q?.id ?? "")","answers":[{"picks":[1]}]}"#))
        check(code(mac) == .failed && b.answered.isEmpty, "hub session: answer a screen-read question -> failed, nothing sent")
        // Codex async question (answered by a message): the app does not answer it either.
        let cb = FakeHubBackend(workspaces: ws(.idle, kind: "codex"))
        let cq = QuestionRequest(toolUseId: "call_1", agent: "codex", delivery: .message, questions: [.init(header: "", text: "Which?", options: [.init(label: "A")])])
        cb.items["s1"] = [ConversationItem(id: "q", kind: .question(cq))]
        cb.screens["w1:p1"] = "› "
        let (cs, _) = await session(cb)
        check(code(await cs.receive(msg(#"{"v":1,"type":"answer","id":"c4","pane":"w1:p1","question":"call_1","answers":[{"picks":[0]}]}"#))) == .failed && cb.answered.isEmpty,
              "hub session: a message-delivery question -> failed")
        check(code(await cs.receive(msg(#"{"v":1,"type":"send","id":"c5","pane":"w1:p1","text":"A"}"#))) == .promptOpen, "hub session: open Codex question blocks send too")
        // A logged Codex picker question: the phone answers it when herdr gives the agent's session, else the Mac
        // does (the session was found from the log path, so no key gate can bind to the agent).
        let pq = QuestionRequest(toolUseId: "call_2", agent: "codex", questions: [.init(header: "", text: "Which?", options: [.init(label: "A"), .init(label: "B")])])
        for resolvedSession in [false, true] {
            var w = ws(.blocked, kind: "codex")
            w[0].tabs[0].panes[0].agent?.sessionResolved = resolvedSession
            let pb = FakeHubBackend(workspaces: w)
            pb.items["s1"] = [ConversationItem(id: "q", kind: .question(pq))]
            pb.screens["w1:p1"] = "  Question 1/1"
            let (ps, _) = await session(pb)
            let pw = await ps.receive(msg(#"{"v":1,"type":"watch","id":"c6","pane":"w1:p1"}"#))
            let hq: HubQuestion? = pw.compactMap { if case .prompt(let p) = $0 { p.question } else { nil } }.first
            let a = await ps.receive(msg(#"{"v":1,"type":"answer","id":"c7","pane":"w1:p1","question":"call_2","answers":[{"picks":[0]}]}"#))
            if resolvedSession {
                check(hq?.onMac == true && code(a) == .failed && pb.answered.isEmpty,
                      "hub session: an agent without a herdr session -> its question is onMac, answer failed, nothing sent")
            } else {
                check(hq != nil && hq?.onMac == nil && reply(a)?.ok == true && pb.answered.count == 1, "hub session: a herdr session -> the phone answers")
            }
        }
    }

    // Revoke and level changes take effect on the next message.
    do {
        let b = FakeHubBackend(workspaces: ws(.idle)); b.screens["w1:p1"] = "❯ "
        let local = MemoryDeviceStore()
        local.add(token: "t", device: HubDevice(id: "d", name: "Phone", level: .read))
        let s = HubSession(backend: b, devices: local)
        _ = await s.receive(msg(#"{"v":1,"type":"hello","id":"h","token":"t","client":"test","clientVersion":"1"}"#))
        check(code(await s.receive(msg(#"{"v":1,"type":"send","id":"c1","pane":"w1:p1","text":"a"}"#))) == .readOnly, "hub session: read before the level change")
        local.setLevel(.input, device: "d")
        check(reply(await s.receive(msg(#"{"v":1,"type":"send","id":"c2","pane":"w1:p1","text":"b"}"#)))?.ok == true, "hub session: input after the level change")
        local.revoke(device: "d")
        let r = await s.receive(msg(#"{"v":1,"type":"ping","id":"c3"}"#))
        check(code(r) == .unauthorized && s.closed, "hub session: revoked device -> unauthorized, closed")
    }
}
