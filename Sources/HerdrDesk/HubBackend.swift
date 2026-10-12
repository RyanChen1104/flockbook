import HerdrKit
import Foundation

/// The remote hub's view of the app: the same store, the same writes setting and the same input paths as the cards
/// and the composer. `HubSession` checks the prompt and the level before it calls a write here.
@MainActor final class AppHubBackend: HubBackend {
    let model: AppModel
    init(model: AppModel) { self.model = model }

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
    func send(pane id: String, text: String, images: [URL]) async -> HubSendResult {
        guard model.writesEnabled else { return .failed }
        // herdr has no compare-and-send: this read and the keys are two calls, so a small window stays.
        guard await store.client.readyForText(paneId: id) else { return .changed }
        model.noteSent(id)
        let message = ([text] + images.map(ComposerHandle.quoted)).filter { !$0.isEmpty }.joined(separator: " ")
        return await MessageSender.send(message, to: id, client: store.client) ? .sent : .failed
    }

    /// The approval card's keys, without its UI follow-up (the Mac window does not change for a phone action).
    /// Re-reads the pane right before the keys (`respondIfOpen`): false, and nothing sent, when the prompt changed.
    func approve(pane id: String, prompt: String, allow: Bool) async -> Bool {
        guard model.writesEnabled, let p = pane(id), let a = p.agent else { return false }
        guard (try? await store.client.respondIfOpen(paneId: id, prompt: prompt, allow: allow, agentKind: a.kind,
                                                    blocked: a.status == .blocked, pending: model.pendingRequest(p))) == true else { return false }
        try? await Task.sleep(for: .seconds(1))
        await store.refresh()
        if let p = pane(id) { await model.checkPrompt(for: p) }
        return true
    }

    /// The question card's path. Questions not read yet are read first (moves Claude's picker, navigation only);
    /// the answers must then cover every question, else nothing is sent.
    func answer(pane id: String, question: QuestionRequest, answers: [QuestionAnswer]) async throws {
        guard model.writesEnabled else { throw QuestionAdapter.Failure.unsupported("input is off") }
        var q = question
        if q.unread > 0 {
            guard let full = try await store.client.loadAllQuestions(paneId: id) else { throw QuestionAdapter.Failure.notOnScreen }
            q = full
        }
        guard answers.count == q.questions.count else {
            throw QuestionAdapter.Failure.unsupported("\(q.questions.count) questions, \(answers.count) answers")
        }
        try await store.client.answerQuestion(paneId: id, request: q, answers: answers)
    }
}
