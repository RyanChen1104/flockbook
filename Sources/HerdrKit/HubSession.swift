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
    /// Where re-encoded images from remote devices go (the composer's image folder). Nil: images are refused.
    var imageDirectory: URL? { get }
    /// Types the text, then the image files' paths, and submits, as the composer does.
    /// `agent`: the agent the checks saw (refuse when another one is in the pane now). `allowed`: asked again right
    /// before each key goes out (the device's level and Allow input now); false -> nothing more is sent.
    func send(pane: String, text: String, images: [URL], agent: Agent, allowed: @escaping @MainActor @Sendable () -> Bool) async -> HubSendResult
    /// The approval card's input (`HerdrClient.respond`). Called only after the prompt was checked.
    func approve(pane: String, prompt: String, allow: Bool, agent: Agent, allowed: @escaping @MainActor @Sendable () -> Bool) async -> Bool
    /// The question card's input. Called only after the question was checked.
    func answer(pane: String, question: QuestionRequest, answers: [QuestionAnswer], agent: Agent, allowed: @escaping @MainActor @Sendable () -> Bool) async throws
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

    /// Image uploads: the per-device limit (one limiter per hub), the open upload, and the finished unsent ones.
    private let uploads: HubUploadLimiter
    private struct OpenUpload { var name: String; var parts: Int; var next: Int; var data: Data }
    private var openUpload: OpenUpload?
    private var held: [(name: String, url: URL)] = []
    /// Counts `discard` calls, so an upload that finishes after one is deleted, not held.
    private var discards = 0
    /// Uploads held per connection.
    public static let maxHeld = 4

    public init(backend: HubBackend, devices: HubDeviceStore, pairing: HubPairing? = nil, source: String = "", uploads: HubUploadLimiter? = nil) {
        self.backend = backend; self.devices = devices; self.pairing = pairing; self.source = source
        self.uploads = uploads ?? HubUploadLimiter()
    }

    /// Test hook: runs after an image is decoded, before it is held.
    var afterDecode: (@MainActor () -> Void)?
    /// The level at hello, and the device whose connection slot this connection holds.
    private var helloLevel: HubLevel?
    private var slot: String?

    /// The device's level now differs from the one at hello (changed or revoked): the connection is closed, and
    /// the client says hello again to learn its level.
    public var levelChanged: Bool { deviceID != nil && device?.level != helloLevel }
    /// Input allowed right now: the device's level and the app's Allow input, looked up again on every call.
    /// Checked after every wait and again right before the keys (the backend asks `allowed`).
    private var inputAllowed: Bool { !closed && device?.level == .input && backend.writesEnabled }

    /// The connection ends for good: `discard`, and the device's connection slot is freed.
    public func end() {
        closed = true
        discard()
        if let d = slot { uploads.disconnect(device: d); slot = nil }
    }

    /// The connection ends: unsent uploads and their files go.
    public func discard() {
        discards += 1
        openUpload = nil
        for h in held { try? FileManager.default.removeItem(at: h.url) }
        if let d = deviceID, !held.isEmpty { uploads.release(device: d, count: held.count) }
        held.removeAll()
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
            guard deviceID == nil || deviceID == d.id else { return [fail(m.id, .badRequest, "This connection belongs to another device.")] }
            if slot == nil {
                guard uploads.connect(device: d.id) else {
                    closed = true
                    return [fail(m.id, .rateLimited, "Too many connections from this device. Close another one.")]
                }
                slot = d.id
            }
            deviceID = d.id
            helloLevel = d.level
            lastSnapshot = snapshot()
            return [.welcome(HubWelcome(hub: backend.hubName, hubVersion: backend.hubVersion, level: d.level, session: backend.sessionName)),
                    .snapshot(lastSnapshot ?? []), ok(m.id)]
        }
        guard let device else { closed = true; return [fail(m.id, .unauthorized, deviceID == nil ? "Send hello first." : "This device was removed.")] }
        let canInput = inputAllowed
        let allowed: @MainActor @Sendable () -> Bool = { [weak self] in self?.inputAllowed ?? false }
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
        case .attach(let name, let part, let parts, let data):
            guard canInput else { return [readOnly(m.id)] }
            return await attach(m.id, device: device, name: name, part: part, parts: parts, base64: data)
        case .send(let id, let text, let attachments):
            guard canInput else { return [readOnly(m.id)] }
            guard let p = pane(id) else { return [fail(m.id, .notFound, "No pane \(id).")] }
            // A plain shell is never typed into from a remote device.
            guard p.agent != nil else { return [fail(m.id, .readOnly, "Remote input goes to agents only.")] }
            if let why = Hub.inputProblem(text, limit: Hub.maxSendText) { return [fail(m.id, .badRequest, why)] }
            guard attachments.count <= Hub.maxAttachments else { return [fail(m.id, .badRequest, "At most \(Hub.maxAttachments) images per message.")] }
            guard Set(attachments).count == attachments.count else { return [fail(m.id, .badRequest, "An image is named twice.")] }
            let images = attachments.compactMap { n in held.first { $0.name == n }?.url }
            guard images.count == attachments.count else { return [fail(m.id, .badRequest, "Unknown image. Attach it again. Nothing was sent.")] }
            guard !text.isEmpty || !images.isEmpty else { return [fail(m.id, .badRequest, "Nothing to send.")] }
            let st = await state(p)
            guard inputAllowed else { return [readOnly(m.id)] }
            guard let screen = st.screen else { return [unreadable(m.id)] }
            guard st.approval == nil, st.question == nil, !st.unreadablePrompt, p.agent?.status != .blocked, !Hub.screenTakesKeys(screen) else {
                return [fail(m.id, .promptOpen, "A prompt is open in this pane. Nothing was sent.")]
            }
            // The backend reads the pane once more right before the keys (`HerdrClient.readyForText`).
            let result = await backend.send(pane: id, text: text, images: images, agent: p.agent ?? Agent(name: "", kind: "", status: .idle, sessionId: nil, title: ""), allowed: allowed)
            if result == .sent {
                // Sent: the files stay for the agent (the folder's purge removes them later).
                let gone = held.filter { attachments.contains($0.name) }.count
                held.removeAll { attachments.contains($0.name) }
                uploads.release(device: device.id, count: gone)
            }
            if result != .sent, !inputAllowed { return [readOnly(m.id)] }
            switch result {
            case .sent: return [ok(m.id)]
            case .changed: return [fail(m.id, .promptOpen, "The pane changed before the text went out. Nothing was sent.")]
            case .failed: return [fail(m.id, .failed, "herdr did not take the message.")]
            }
        case .approve(let id, let prompt, let allow):
            guard canInput else { return [readOnly(m.id)] }
            guard let p = pane(id) else { return [fail(m.id, .notFound, "No pane \(id).")] }
            let st = await state(p)
            guard inputAllowed else { return [readOnly(m.id)] }
            guard st.screen != nil else { return [unreadable(m.id)] }
            let action = (allow ? ApprovalNotice.Action.allow : .deny).rawValue
            guard case .send(let a) = ApprovalNotice.outcome(actionIdentifier: action, boundPrompt: prompt, now: st.pane, writes: true) else {
                return [fail(m.id, .stale, "The prompt changed. Nothing was sent.")]
            }
            guard await backend.approve(pane: id, prompt: prompt, allow: a, agent: p.agent ?? Agent(name: "", kind: "", status: .idle, sessionId: nil, title: ""), allowed: allowed) else {
                if !inputAllowed { return [readOnly(m.id)] }
                return [fail(m.id, .stale, "The prompt changed before the keys went out. Nothing was sent.")]
            }
            return [ok(m.id)]
        case .answer(let id, let question, let answers):
            guard canInput else { return [readOnly(m.id)] }
            guard let p = pane(id) else { return [fail(m.id, .notFound, "No pane \(id).")] }
            for a in answers { if let o = a.other, let why = Hub.inputProblem(o, limit: Hub.maxOtherText) { return [fail(m.id, .badRequest, why)] } }
            let st = await state(p)
            guard inputAllowed else { return [readOnly(m.id)] }
            guard st.screen != nil else { return [unreadable(m.id)] }
            guard let q = st.question, q.toolUseId == question else { return [fail(m.id, .stale, "The question changed. Nothing was sent.")] }
            guard q.delivery == .picker else { return [fail(m.id, .failed, "Answer this question in the terminal.")] }
            do {
                try await backend.answer(pane: id, question: q, answers: answers.map { QuestionAnswer(picks: $0.picks, other: $0.other) }, agent: p.agent ?? Agent(name: "", kind: "", status: .idle, sessionId: nil, title: ""), allowed: allowed)
                return [ok(m.id)]
            } catch {
                if !inputAllowed { return [readOnly(m.id)] }
                return [fail(m.id, .failed, "\(error)")]
            }
        }
    }

    /// Pushes since the last call: a new snapshot, and for watched panes new items, screen and prompt changes.
    public func tick() async -> [HubMessage] {
        guard !closed, deviceID != nil else { return [] }
        guard device != nil, !levelChanged else { closed = true; return [] }
        var out: [HubMessage] = []
        let snap = snapshot()
        if snap != lastSnapshot { lastSnapshot = snap; out.append(.snapshot(snap)) }
        for id in watched {
            if let p = pane(id) { out += await pushes(p, force: false) }
        }
        return out
    }

    // MARK: - Images

    private static func uploadName(_ s: String) -> Bool {
        (1...32).contains(s.count) && s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }
    }

    /// One `attach` part (remote-protocol.md 3.3). Any refused part drops the open upload.
    private func attach(_ re: String, device: HubDevice, name: String, part: Int, parts: Int, base64: String) async -> [HubMessage] {
        guard let dir = backend.imageDirectory else { return [fail(re, .failed, "This hub takes no images.")] }
        let open = openUpload
        openUpload = nil
        func bad(_ why: String) -> [HubMessage] { [fail(re, .badRequest, why)] }
        guard Self.uploadName(name) else { return bad("Upload names are 1-32 letters, digits, _ or -.") }
        guard (1...HubImage.maxParts).contains(parts), (0..<parts).contains(part) else { return bad("An image has 1-\(HubImage.maxParts) parts.") }
        if let open {
            guard open.name == name, open.parts == parts, open.next == part else { return bad("Parts of one image come in order, one image at a time.") }
        } else {
            guard part == 0 else { return bad("Parts of one image come in order, one image at a time.") }
            guard !held.contains(where: { $0.name == name }) else { return bad("Upload \(name) is already held.") }
            // The device holds its cap over all its connections (this one could only free a slot by dropping its own).
            guard held.count >= Self.maxHeld || uploads.held(device: device.id) < HubUploadLimiter.maxHeld else { return [tooMany(re)] }
        }
        // Base64 of 640 KiB is under 874 KiB; a longer string is refused before decoding.
        let size = base64.utf8.count
        guard size <= (HubImage.maxPartBytes + 2) / 3 * 4 else { return bad("A part is at most \(HubImage.maxPartBytes / 1024) KiB.") }
        guard (open?.data.count ?? 0) + size / 4 * 3 <= HubImage.maxBytes else { return bad("An image is at most \(HubImage.maxBytes / 1024 / 1024) MiB.") }
        // The limit is counted before any decoding, by the size the string decodes to.
        guard uploads.take(device: device.id, bytes: size / 4 * 3, image: part == 0) else { return [tooMany(re)] }
        guard let data = Data(base64Encoded: base64) else { return bad("Part data is not base64.") }
        guard data.count <= HubImage.maxPartBytes else { return bad("A part is at most \(HubImage.maxPartBytes / 1024) KiB.") }
        let all = (open?.data ?? Data()) + data
        guard part == parts - 1 else {
            openUpload = OpenUpload(name: name, parts: parts, next: part + 1, data: all)
            return [ok(re)]
        }
        // Decoding is off the main thread, at most 2 at once for the hub; a `discard` meanwhile deletes the result.
        // The folder's own files are capped right after (count, bytes, age).
        let round = discards
        let result = await HubWorkSlots.images.run { () -> Result<HubImage.Output, HubImage.Failure> in
            do {
                let out = try HubImage.reencode(all, into: dir)
                HubImage.purge(dir)
                return .success(out)
            } catch { return .failure(error as? HubImage.Failure ?? .undecodable) }
        }
        afterDecode?()
        switch result {
        case .failure(let f):
            switch f {
            case .notImage: return bad("Not a PNG, JPEG, HEIC or WebP image.")
            case .tooLarge: return bad("The image is too large (at most \(HubImage.maxSide) px a side, \(HubImage.maxPixels / 1_000_000) megapixels).")
            case .undecodable: return bad("The image could not be read.")
            case .writeFailed: return [fail(re, .failed, "The hub could not store the image.")]
            }
        case .success(let out):
            uploads.count(device: device.id, bytes: out.bytes)
            guard round == discards, !held.contains(where: { $0.name == name }) else {
                try? FileManager.default.removeItem(at: out.url)
                return bad("The upload was dropped.")
            }
            // Downgraded or revoked while decoding: the file goes.
            guard inputAllowed else { try? FileManager.default.removeItem(at: out.url); return [readOnly(re)] }
            if held.count >= Self.maxHeld {
                try? FileManager.default.removeItem(at: held.removeFirst().url)
                uploads.release(device: device.id)
            }
            guard uploads.hold(device: device.id) else { try? FileManager.default.removeItem(at: out.url); return [tooMany(re)] }
            held.append((name, out.url))
            return [.attached(HubAttached(upload: name, width: out.width, height: out.height, bytes: out.bytes)), ok(re)]
        }
    }

    // MARK: - Helpers

    private func snapshot() -> [HubWorkspace] { backend.workspaces.map(HubWorkspace.init) }
    private func pane(_ id: String) -> Pane? { backend.workspaces.lazy.flatMap(\.tabs).flatMap(\.panes).first { $0.id == id } }
    private func ok(_ re: String) -> HubMessage { .reply(HubReply(re: re, ok: true)) }
    private func fail(_ re: String, _ code: HubError.Code, _ message: String) -> HubMessage {
        .reply(HubReply(re: re, ok: false, error: HubError(code: code, message: message)))
    }
    private func readOnly(_ re: String) -> HubMessage { fail(re, .readOnly, "Input is off for this device.") }
    private func tooMany(_ re: String) -> HubMessage { fail(re, .rateLimited, "Too many images from this device. Try again in a few minutes.") }
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
