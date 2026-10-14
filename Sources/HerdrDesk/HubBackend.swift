import CryptoKit
import HerdrKit
import Foundation

/// The remote hub's view of the app: the same store, the same writes setting and the same input paths as the cards
/// and the composer. `HubSession` checks the prompt and the level before it calls a write here.
@MainActor final class AppHubBackend: HubBackend {
    let model: AppModel
    /// Web Push: the phones' subscriptions and the hub's VAPID key. No key: the hub offers no push.
    let pushes: MemoryPushStore?
    let vapid: P256.Signing.PrivateKey?
    init(model: AppModel, pushes: MemoryPushStore? = nil, vapid: P256.Signing.PrivateKey? = nil) {
        self.model = model; self.pushes = pushes; self.vapid = vapid
    }

    private var store: HerdrStore { model.store }
    private func pane(_ id: String) -> Pane? { store.workspaces.lazy.flatMap(\.tabs).flatMap(\.panes).first { $0.id == id } }

    var hubName: String { Host.current().localizedName ?? "Mac" }
    var hubVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    var sessionName: String? { store.session.name }
    var workspaces: [Workspace] { store.workspaces }
    var writesEnabled: Bool { model.writesEnabled }

    func conversation(session: String) -> [ConversationItem] { store.conversation(for: session) }
    /// The store does not say if the log has more; the client learns it from `loadEarlier`.
    func hasEarlier(session: String) -> Bool { true }
    func loadEarlier(session: String) async -> Bool { await store.loadEarlier(for: session) }
    func screen(pane: String) async -> String? { try? await store.client.visibleText(paneId: pane) }

    /// The composer's image folder: `MessageSender` waits for the agent's image marker on paths in it.
    var imageDirectory: URL? { PasteImages.directory }

    /// The composer's send: the text, then the image paths (quoted as the composer does).
    /// `allowed` (the device's level and Allow input now) is asked before the read and before every key step.
    func send(pane id: String, text: String, images: [URL], agent: Agent, allowed: @escaping @MainActor @Sendable () -> Bool) async -> HubSendResult {
        let model = model
        let may: @MainActor @Sendable () -> Bool = { model.writesEnabled && allowed() }
        guard may() else { return .failed }
        // herdr has no compare-and-send: this read and the keys are two calls, so a small window stays.
        guard await store.client.readyForText(paneId: id, agent: agent) else { return .changed }
        guard may() else { return .failed }
        // Every image must still be a file of ours; else nothing is sent (it would go as plain text).
        guard images.allSatisfy({ ImagePaste.ownFile($0.path) }) else { return .failed }
        model.noteSent(id)
        let message = ([text] + images.map(ComposerHandle.quoted)).filter { !$0.isEmpty }.joined(separator: " ")
        return await MessageSender.send(message, to: id, client: store.client, kind: agent.kind,
                                        gate: KeyGate(agent: agent, allowed: may)) ? .sent : .failed
    }

    /// The approval card's keys, without its UI follow-up (the Mac window does not change for a phone action).
    /// Re-reads the pane right before the keys (`respondIfOpen`): false, and nothing sent, when the prompt, the agent
    /// (kind and session from the hub's check) or the device's level changed.
    func approve(pane id: String, prompt: String, allow: Bool, agent: Agent, allowed: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        let model = model
        let gate = KeyGate(agent: agent, allowed: { model.writesEnabled && allowed() })
        guard model.writesEnabled, allowed(), let p = pane(id), let a = p.agent else { return false }
        guard (try? await store.client.respondIfOpen(paneId: id, prompt: prompt, allow: allow, agentKind: a.kind,
                                                    blocked: a.status == .blocked, pending: model.pendingRequest(p), gate: gate)) == true else { return false }
        try? await Task.sleep(for: .seconds(1))
        await store.refresh()
        if let p = pane(id) { await model.checkPrompt(for: p) }
        return true
    }

    /// The hook's newest AskUserQuestion call for this session (the files the hook wrote, read-only).
    func hookedQuestion(session: String) -> QuestionRequest? { ClaudeHookSetup.live.question(session: session) }
    var pushKey: String? { vapid.map { Base64URL.encode($0.publicKey.x963Representation) } }
    func pushSubscribe(_ s: PushSubscription) -> Bool { vapid != nil && pushes?.add(s) == true }
    func pushUnsubscribe(device: String, endpoint: String) { pushes?.remove(device: device, endpoint: endpoint) }
    func pushSubscribed(device: String) -> Bool { pushes?.all.contains { $0.device == device } == true }

    /// The question card's path. Questions not read yet are read first (moves Claude's picker, navigation only);
    /// the answers must then cover every question, else nothing is sent. Every key is gated: the agent from the
    /// hub's check, this question's picker on screen, the device's level now (`KeyGate`).
    func answer(pane id: String, question: QuestionRequest, answers: [QuestionAnswer], agent: Agent, allowed: @escaping @MainActor @Sendable () -> Bool) async throws {
        let model = model
        let gate = KeyGate(agent: agent, allowed: { model.writesEnabled && allowed() })
        guard model.writesEnabled, allowed() else { throw QuestionAdapter.Failure.unsupported("input is off") }
        var q = question
        if q.unread > 0 {
            // Bound to the request the client answered: another request on screen now (even with as many questions) is refused.
            guard let full = try await store.client.loadAllQuestions(paneId: id, gate: gate, expect: question),
                  QuestionAdapter.sameRequest(full, as: question) else { throw QuestionAdapter.Failure.notOnScreen }
            q = full
        }
        guard answers.count == q.questions.count else {
            throw QuestionAdapter.Failure.unsupported("\(q.questions.count) questions, \(answers.count) answers")
        }
        guard model.writesEnabled, allowed() else { throw QuestionAdapter.Failure.unsupported("input is off") }
        try await store.client.answerQuestion(paneId: id, request: q, answers: answers, gate: gate)
    }
}
