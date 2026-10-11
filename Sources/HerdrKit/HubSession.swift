import Foundation
import CryptoKit

// The hub's protocol logic for one connection (remote protocol v1, docs/design/remote-protocol.md), without a
// network: messages in, messages out. `HubServer` carries it over WebSocket. The app gives the data and the
// input paths through `HubBackend`, and the paired devices through `HubDeviceStore`.

/// What the hub needs from the app. Input goes through the app's own paths (composer send, approval card, question card).
@MainActor public protocol HubBackend: AnyObject {
    var hubName: String { get }
    var hubVersion: String { get }
    /// herdr session name; nil = the default session.
    var sessionName: String? { get }
    var workspaces: [Workspace] { get }
    /// The app-wide "Allow input" setting (and not a read-only launch).
    var writesEnabled: Bool { get }
    func conversation(session: String) -> [ConversationItem]
    /// The log may hold items older than `conversation(session:)` has.
    func hasEarlier(session: String) -> Bool
    /// Loads older items into `conversation(session:)`. True while still older content remains.
    func loadEarlier(session: String) async -> Bool
    /// The pane's visible screen text (read-only).
    func screen(pane: String) async -> String?
    /// Types the text and submits it, as the composer does. False when herdr did not take it.
    func send(pane: String, text: String) async -> HubSendResult
    /// The approval card's input (`HerdrClient.respond`). Called only after the prompt was checked.
    func approve(pane: String, prompt: String, allow: Bool) async -> Bool
    /// The question card's input. Called only after the question was checked.
    func answer(pane: String, question: QuestionRequest, answers: [QuestionAnswer]) async throws
}

public enum HubSendResult: Sendable, Hashable { case sent, changed, failed }

public struct HubDevice: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var level: HubLevel
    public init(id: String, name: String, level: HubLevel) { self.id = id; self.name = name; self.level = level }
}

extension ApprovalNotice {
    /// The approval card's request from the log: the last permission request, when it is still pending.
    public static func pendingRequest(in items: [ConversationItem]) -> PermissionRequest? {
        for item in items.reversed() { if case .permissionRequest(let r) = item.kind { return r.state == .pending ? r : nil } }
        return nil
    }
}

extension Hub {
    /// The question a pane waits on, as the app's question card finds it: Claude's picker on screen (blocked only),
    /// else a pending question that ends the log while the agent is not working (Codex).
    public static func openQuestion(agent: Agent?, screen: String?, items: [ConversationItem]) -> QuestionRequest? {
        guard let agent else { return nil }
        if agent.kind == "claude", agent.status == .blocked, let screen, let shown = QuestionAdapter.claudeScreen(screen) {
            return QuestionAdapter.screenRequest(headers: shown.headers, questions: [shown.question])
        }
        guard agent.status != .working, let last = items.last, case .question(let q) = last.kind, q.state == .pending else { return nil }
        return q
    }
}

@MainActor public final class HubSession {
    /// Items sent on `watch` and per `loadEarlier`.
    public static let window = 100

    private let backend: HubBackend
    private let devices: HubDeviceStore
    public private(set) var closed = false
    private var deviceID: String?
    private var watched: [String] = []
    private var lastSnapshot: [HubWorkspace]?
    private var sent: [String: [HubItem]] = [:]
    private var lastScreen: [String: String] = [:]
    private var lastPrompt: [String: HubPrompt] = [:]

    private let pairing: HubPairing?

    /// `pairing` nil: `pair` is refused (the hub shows no offer).
    /// `source`: the peer's address; wrong pairing tries are counted per source.
    private let source: String

    public init(backend: HubBackend, devices: HubDeviceStore, pairing: HubPairing? = nil, source: String = "") {
        self.backend = backend; self.devices = devices; self.pairing = pairing; self.source = source
    }

    /// The device of this connection, looked up again each time (nil after a revoke).
    public var device: HubDevice? { deviceID.flatMap { devices.device(id: $0) } }
    /// Said hello once, and its device is gone now.
    public var revoked: Bool { deviceID != nil && device == nil }

    /// One client message: the pushes it causes, then its reply.
    public func receive(_ data: Data) async -> [HubMessage] {
        guard !closed else { return [] }
        let rid = Self.requestID(data)
        let m: ClientMessage
        do { m = try Hub.decodeClient(data) } catch Hub.DecodeError.unsupportedVersion(let v) {
            closed = true
            return [fail(rid, .unsupportedVersion, "This hub speaks protocol \(Hub.version), not \(v).")]
        } catch {
            return [fail(rid, .badRequest, "Not a protocol \(Hub.version) client message.")]
        }
        if case .pair(let secret, let name) = m.body {
            guard deviceID == nil else { return [fail(m.id, .badRequest, "This connection is already paired.")] }
            guard let (token, d) = pairing?.redeem(secret, name: name, source: source) else {
                closed = true
                return [fail(m.id, .unauthorized, "Wrong or expired pairing code. Start pairing again on the hub.")]
            }
            return [.paired(HubPaired(token: token, device: d)), ok(m.id)]
        }
        if case .hello(let token, _, _) = m.body {
            guard let d = devices.device(token: token) else { closed = true; return [fail(m.id, .unauthorized, "Unknown device. Pair it on the hub.")] }
            deviceID = d.id
            lastSnapshot = snapshot()
            return [.welcome(HubWelcome(hub: backend.hubName, hubVersion: backend.hubVersion, level: d.level, session: backend.sessionName)),
                    .snapshot(lastSnapshot ?? []), ok(m.id)]
        }
        guard let device else { closed = true; return [fail(m.id, .unauthorized, deviceID == nil ? "Send hello first." : "This device was removed.")] }
        let canInput = device.level == .input && backend.writesEnabled
        switch m.body {
        case .hello, .pair:
            return []   // handled above
        case .ping:
            return [.pong, ok(m.id)]
        case .watch(let id):
            guard let p = pane(id) else { return [fail(m.id, .notFound, "No pane \(id).")] }
            if !watched.contains(id) { watched.append(id) }
            return await pushes(p, force: true) + [ok(m.id)]
        case .unwatch(let id):
            watched.removeAll { $0 == id }
            sent[id] = nil; lastScreen[id] = nil; lastPrompt[id] = nil
            return [ok(m.id)]
        case .loadEarlier(let session, let before):
            return await loadEarlier(session: session, before: before, re: m.id)
        case .send(let id, let text):
            guard canInput else { return [readOnly(m.id)] }
            guard let p = pane(id) else { return [fail(m.id, .notFound, "No pane \(id).")] }
            // A plain shell is never typed into from a remote device.
            guard p.agent != nil else { return [fail(m.id, .readOnly, "Remote input goes to agents only.")] }
            if let why = Hub.inputProblem(text, limit: Hub.maxSendText) { return [fail(m.id, .badRequest, why)] }
            let st = await state(p)
            guard let screen = st.screen else { return [unreadable(m.id)] }
            guard st.approval == nil, st.question == nil, !st.unreadablePrompt, p.agent?.status != .blocked, !Hub.screenTakesKeys(screen) else {
                return [fail(m.id, .promptOpen, "A prompt is open in this pane. Nothing was sent.")]
            }
            // The backend reads the pane once more right before the keys (`HerdrClient.readyForText`).
            switch await backend.send(pane: id, text: text) {
            case .sent: return [ok(m.id)]
            case .changed: return [fail(m.id, .promptOpen, "The pane changed before the text went out. Nothing was sent.")]
            case .failed: return [fail(m.id, .failed, "herdr did not take the message.")]
            }
        case .approve(let id, let prompt, let allow):
            guard canInput else { return [readOnly(m.id)] }
            guard let p = pane(id) else { return [fail(m.id, .notFound, "No pane \(id).")] }
            let st = await state(p)
            guard st.screen != nil else { return [unreadable(m.id)] }
            let action = (allow ? ApprovalNotice.Action.allow : .deny).rawValue
            guard case .send(let a) = ApprovalNotice.outcome(actionIdentifier: action, boundPrompt: prompt, now: st.pane, writes: true) else {
                return [fail(m.id, .stale, "The prompt changed. Nothing was sent.")]
            }
            guard await backend.approve(pane: id, prompt: prompt, allow: a) else {
                return [fail(m.id, .stale, "The prompt changed before the keys went out. Nothing was sent.")]
            }
            return [ok(m.id)]
        case .answer(let id, let question, let answers):
            guard canInput else { return [readOnly(m.id)] }
            guard let p = pane(id) else { return [fail(m.id, .notFound, "No pane \(id).")] }
            for a in answers { if let o = a.other, let why = Hub.inputProblem(o, limit: Hub.maxOtherText) { return [fail(m.id, .badRequest, why)] } }
            let st = await state(p)
            guard st.screen != nil else { return [unreadable(m.id)] }
            guard let q = st.question, q.toolUseId == question else { return [fail(m.id, .stale, "The question changed. Nothing was sent.")] }
            guard q.delivery == .picker else { return [fail(m.id, .failed, "Answer this question in the terminal.")] }
            do {
                try await backend.answer(pane: id, question: q, answers: answers.map { QuestionAnswer(picks: $0.picks, other: $0.other) })
                return [ok(m.id)]
            } catch {
                return [fail(m.id, .failed, "\(error)")]
            }
        }
    }

    /// Pushes since the last call: a new snapshot, and for watched panes new items, screen and prompt changes.
    public func tick() async -> [HubMessage] {
        guard !closed, deviceID != nil else { return [] }
        guard device != nil else { closed = true; return [] }
        var out: [HubMessage] = []
        let snap = snapshot()
        if snap != lastSnapshot { lastSnapshot = snap; out.append(.snapshot(snap)) }
        for id in watched {
            if let p = pane(id) { out += await pushes(p, force: false) }
        }
        return out
    }

    // MARK: - Helpers

    private func snapshot() -> [HubWorkspace] { backend.workspaces.map(HubWorkspace.init) }
    private func pane(_ id: String) -> Pane? { backend.workspaces.lazy.flatMap(\.tabs).flatMap(\.panes).first { $0.id == id } }
    private func ok(_ re: String) -> HubMessage { .reply(HubReply(re: re, ok: true)) }
    private func fail(_ re: String, _ code: HubError.Code, _ message: String) -> HubMessage {
        .reply(HubReply(re: re, ok: false, error: HubError(code: code, message: message)))
    }
    private func readOnly(_ re: String) -> HubMessage { fail(re, .readOnly, "Input is off for this device.") }
    /// Fail closed: without the screen the hub cannot tell what the keys would answer.
    private func unreadable(_ re: String) -> HubMessage { fail(re, .failed, "Could not read the pane. Nothing was sent.") }

    /// The id of a message that did not decode, so its error reply can still name it.
    static func requestID(_ data: Data) -> String {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"] as? String ?? ""
    }

    private struct PaneNow {
        var screen: String?
        var pane: ApprovalNotice.PaneState?
        var approval: HubApproval?
        var question: QuestionRequest?
        /// A permission prompt on screen that the parser cannot read: counted as open.
        var unreadablePrompt = false
    }

    /// The pane as it is now: one screen read, the log, and the open prompt by the app's rules.
    private func state(_ p: Pane) async -> PaneNow {
        let screen = await backend.screen(pane: p.id)
        let items = p.agent?.sessionId.map { backend.conversation(session: $0) } ?? []
        let logged = ApprovalNotice.pendingRequest(in: items)
        let ps = p.agent.map { ApprovalNotice.PaneState(agentKind: $0.kind, blocked: $0.status == .blocked, pendingToolUseId: logged?.toolUseId, screen: screen ?? "",
                                                        pendingTool: logged?.toolName, pendingCommand: logged?.command) }
        let approval = ps.flatMap { Hub.openApproval($0, logged: logged) }
        let question = Hub.openQuestion(agent: p.agent, screen: screen, items: items)
        let unreadable = approval == nil && question == nil && p.agent?.kind == "claude"
            && Hub.unreadablePrompt(screen: screen ?? "", blocked: p.agent?.status == .blocked)
        return PaneNow(screen: screen, pane: ps, approval: approval, question: question, unreadablePrompt: unreadable)
    }

    private func pushes(_ p: Pane, force: Bool) async -> [HubMessage] {
        var out: [HubMessage] = []
        if let c = conversationPush(p, force: force) { out.append(c) }
        let st = await state(p)
        if let s = st.screen, force || s != lastScreen[p.id] { lastScreen[p.id] = s; out.append(.screen(pane: p.id, text: s)) }
        let prompt = HubPrompt(pane: p.id, approval: st.approval, question: st.question.map(HubQuestion.init))
        if force || prompt != lastPrompt[p.id] { lastPrompt[p.id] = prompt; out.append(.prompt(prompt)) }
        return out
    }

    /// `append` when the client's items are still a prefix of the log (changed items are sent again by id), else `replace`.
    private func conversationPush(_ p: Pane, force: Bool) -> HubMessage? {
        guard let session = p.agent?.sessionId else { return nil }
        let items = backend.conversation(session: session)
        let old = force ? nil : sent[p.id]
        if let old, let first = old.first, let start = items.firstIndex(where: { $0.id == first.id }) {
            let cur = items[start...].map(HubItem.init)
            if cur.count >= old.count, zip(old, cur).allSatisfy({ $0.id == $1.id }) {
                sent[p.id] = cur
                let delta = zip(old, cur).filter { $0 != $1 }.map(\.1) + cur[old.count...]
                guard !delta.isEmpty else { return nil }
                return .conversation(HubConversation(pane: p.id, session: session, mode: .append, items: delta,
                                                     hasEarlier: start > 0 || backend.hasEarlier(session: session)))
            }
        }
        if let old, old.isEmpty, items.isEmpty { return nil }
        let tail = Array(items.suffix(Self.window).map(HubItem.init))
        if let old, old == tail { return nil }
        sent[p.id] = tail
        return .conversation(HubConversation(pane: p.id, session: session, mode: .replace, items: tail,
                                             hasEarlier: items.count > tail.count || backend.hasEarlier(session: session)))
    }

    private func loadEarlier(session: String, before: String, re: String) async -> [HubMessage] {
        guard let p = backend.workspaces.lazy.flatMap(\.tabs).flatMap(\.panes).first(where: { $0.agent?.sessionId == session }) else {
            return [fail(re, .notFound, "No pane shows session \(session).")]
        }
        var items = backend.conversation(session: session)
        guard var idx = items.firstIndex(where: { $0.id == before }) else { return [fail(re, .notFound, "No item \(before).")] }
        var more = backend.hasEarlier(session: session)
        if idx < Self.window, more || idx == 0 {
            more = await backend.loadEarlier(session: session)
            items = backend.conversation(session: session)
            idx = items.firstIndex { $0.id == before } ?? idx
        }
        let lo = max(0, idx - Self.window)
        let older = items[lo..<idx].map(HubItem.init)
        if let held = sent[p.id], held.first?.id == before { sent[p.id] = older + held }
        return [.conversation(HubConversation(pane: p.id, session: session, mode: .prepend, items: older, hasEarlier: lo > 0 || more)), ok(re)]
    }
}
