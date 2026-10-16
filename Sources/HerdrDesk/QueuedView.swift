import HerdrKit
import SwiftUI

/// The agents' own queues (QueuedInput): read while the agent works, shown faded over the composer, pulled back into it.
extension AppModel {
    /// READ-ONLY: the pane's queue from its screen and log. Nothing unless the agent works and has a queue Flockbook reads.
    func checkQueue(for pane: Pane) async {
        guard let a = pane.agent, a.status == .working, QueuePull.pullKey(agent: a.kind) != nil else {
            if queued[pane.id] != nil { queued[pane.id] = nil }
            return
        }
        let read: QueuedInput?
        if let q = QueueProbe.injected[pane.id] { read = q }   // offscreen shots only (empty in the app)
        else {
            let screen = try? await store.client.visibleText(paneId: pane.id)
            read = QueuedInput.read(agent: a, screen: screen, log: store.queuedInLog(for: a.sessionId))
        }
        let q = read.flatMap { $0.items.isEmpty ? nil : $0 }
        if queued[pane.id] != q { queued[pane.id] = q }
    }

    /// User action only (Pull back): QueuePull takes the agent's queue back (Up or Shift-Left, then Ctrl-U; never Escape)
    /// and the text goes into this pane's composer. It reads the pane before and after the keys; when the turn stopped
    /// or the keys were refused, a notice says so and the log keeps it.
    func pullQueued(_ pane: Pane) {
        guard writesEnabled, let a = pane.agent, !pulling.contains(pane.id) else { return }
        let id = pane.id
        pulling.insert(id)
        Task {
            defer { pulling.remove(id) }
            let io = HerdrQueuePullIO(client: store.client, paneId: id, allowed: { [weak self] in self?.writesEnabled == true })
            let r = await QueuePull.run(expect: a, log: store.queuedInLog(for: a.sessionId), io: io)
            switch r {
            case .pulled(let t):
                noticeLog.info("queue pull pane \(id, privacy: .public): pulled \(t.count) chars")
                putInComposer(t, pane: id)
            case .interrupted(let t):
                noticeLog.error("queue pull pane \(id, privacy: .public): the turn stopped after the keys")
                putInComposer(t, pane: id)
                notice = "The agent's turn stopped after the pull. Your text is in the composer."
            case .refused(let why):
                noticeLog.info("queue pull pane \(id, privacy: .public): refused: \(why, privacy: .public)")
                notice = why
            case .failed(let why):
                noticeLog.error("queue pull pane \(id, privacy: .public): failed: \(why, privacy: .public)")
                notice = why
            }
            QueueProbe.report?(r)
            await store.refresh()
            if let now = store.workspaces.flatMap(\.tabs).flatMap(\.panes).first(where: { $0.id == id }) { await checkQueue(for: now) }
        }
    }

    /// Adds `text` after what the composer holds and starts the composer again from that draft.
    func putInComposer(_ text: String, pane id: String) {
        var d = drafts[id] ?? ComposerDraft()
        d.text = d.text.isEmpty ? text : d.text + "\n" + text
        drafts[id] = d
        composerResets[id, default: 0] += 1
    }
}

/// Test hook for the live check (`--test-queue-live`): what the last pull returned. nil in the app.
/// `injected`: queues by pane id for offscreen shots, read instead of the screen. Empty in the app.
@MainActor enum QueueProbe {
    static var report: ((QueuePull.Outcome) -> Void)?
    static var injected: [String: QueuedInput] = [:]
}

/// The agent's queued messages, faded user bubbles over the composer, with when they go in and Pull back.
struct QueuedStrip: View {
    let queue: QueuedInput
    let canPull: Bool
    let pulling: Bool
    let onPull: () -> Void
    @AppStorage(ReadingSize.key, store: AppDefaults.store) private var sizeRaw = ReadingSize.m.rawValue
    private var size: ReadingSize { ReadingSize(rawValue: sizeRaw) ?? .m }

    private var when: String {
        queue.agent == "claude" ? "Goes in after the current step or when the turn ends." : "Goes in when this turn ends."
    }
    private var pullLabel: String { queue.pullsAll ? "Pull back to edit" : "Pull back the newest" }
    /// What the pull does to the queue, next to the button.
    private var pullNote: String {
        if queue.pullsAll { return queue.items.count > 1 ? "All \(queue.items.count) come back as one message." : "It comes back to the composer." }
        return "Sending it again adds it to the turn now running."
    }
    private var blocked: String? {
        if !queue.pullable { return "The agent's input box has text. Clear it in the terminal to pull back." }
        if queue.items.contains(where: { $0 == nil }) { return "The queued text cannot be read yet." }
        return nil
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(Array(queue.items.enumerated()), id: \.offset) { _, item in
                HStack {
                    Spacer(minLength: min(size.column * 0.2, 120))
                    bubble(item)
                }
            }
            HStack(spacing: 8) {
                Text(blocked ?? "\(when) \(pullNote)").font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                if pulling { ProgressView().controlSize(.small) }
                Button(pullLabel, action: onPull)
                    .controlSize(.small)
                    .disabled(!canPull || blocked != nil || pulling)
                    .help(queue.pullsAll ? "Takes the queue back from the agent into this composer. The turn keeps running."
                                         : "Takes the newest queued message back into this composer. The turn keeps running.")
            }
        }
        .frame(maxWidth: 780)
        .padding(.horizontal, 24).padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued messages")
    }

    private func bubble(_ text: String?) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("Queued").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(text ?? "1 queued message").font(text == nil ? .body.italic() : .body)
                .foregroundStyle(.secondary).textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.bubble))
        .overlay(RoundedRectangle(cornerRadius: Radius.bubble).strokeBorder(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .frame(maxWidth: size.column * 0.8, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
    }
}
