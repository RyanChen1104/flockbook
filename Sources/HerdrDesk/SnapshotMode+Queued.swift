import AppKit
import HerdrKit
import SwiftUI

/// `--snapshot-queued <dir>`: the agent's own queue over the composer (QueuedStrip), offscreen, light and dark, on the
/// preview conversation. Also checks the model side: the queue read while the agent works, a pull's text in the
/// composer. Sends nothing to herdr.
extension SnapshotRunner {
    static func runQueued(dir: String) {
        Task { @MainActor in await queued(dir: dir) }
    }

    @MainActor private static func queued(dir: String) async {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var failures = 0
        func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("snapshot-queued: \(n) \(ok ? "ok" : "FAIL")") }
        let store = HerdrStore.preview
        let panes = store.workspaces.flatMap(\.tabs).flatMap(\.panes)
        guard let pane = panes.first(where: { $0.agent?.status == .working }), let idle = panes.first(where: { $0.agent?.status == .idle }) else {
            step("the preview has a working and an idle agent", false); exit(1)
        }
        let two = ["Also run the lint step before you commit.", "Then open a draft PR with a short summary."]
        let cases: [(String, QueuedInput, Bool, String?)] = [
            ("claude", QueuedInput(agent: "claude", items: two, pullable: true), false, nil),
            ("claude", QueuedInput(agent: "claude", items: two, pullable: true), true, nil),
            ("compacting", QueuedInput(agent: "claude", items: [nil], pullable: true), false, nil),
            ("codex-busy", QueuedInput(agent: "codex", items: ["Check the retry count too."], pullable: false), false, nil),
            ("codex-busy", QueuedInput(agent: "codex", items: ["Check the retry count too."], pullable: false), true, nil),
            ("pulled", QueuedInput(agent: "claude", items: [], pullable: true), false, two.joined(separator: "\n")),
            ("pulled", QueuedInput(agent: "claude", items: [], pullable: true), true, two.joined(separator: "\n")),
        ]
        for (name, q, dark, composer) in cases {
            AppDefaults.store.set(ReadingSize.m.rawValue, forKey: ReadingSize.key)
            let model = AppModel(store: store)
            QueueProbe.injected = [pane.id: q]
            await model.checkQueue(for: pane)
            if let composer {
                model.putInComposer(composer, pane: pane.id)
                step("\(name): the pulled text is the composer's draft", model.drafts[pane.id]?.text == composer && model.composerResets[pane.id] == 1)
                step("\(name): an empty queue shows nothing", model.queued[pane.id] == nil)
            } else {
                step("\(name): the working pane's queue is read", model.queued[pane.id] == q)
            }
            let shown = model.queued[pane.id]
            let size = NSSize(width: 900, height: 640)
            let view = ZStack {
                Color(nsColor: .textBackgroundColor)
                ConversationView(items: store.conversation(for: nil), agentName: pane.agent?.name ?? "claude", hasLog: true)
                    .safeAreaBar(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                            if let shown { QueuedStrip(queue: shown, canPull: true, pulling: false, onPull: {}) }
                            ComposerView(agentName: pane.agent?.name ?? "claude", draft: model.drafts[pane.id] ?? ComposerDraft(), onSend: { _ in })
                                .frame(maxWidth: 780).padding(.horizontal, 24).padding(.bottom, 12).padding(.top, 6)
                        }
                    }
            }
            .environment(\.flatGlass, true).frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: size)
            let win = OffscreenWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            win.contentView = host; win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()
            for _ in 0..<12 { try? await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/queued-\(name)-\(dark ? "dark" : "light").png"))
            }
            win.orderOut(nil)
        }

        let model = AppModel(store: store)
        QueueProbe.injected = [idle.id: QueuedInput(agent: "claude", items: two, pullable: true)]
        model.queued[idle.id] = QueuedInput(agent: "claude", items: two, pullable: true)
        await model.checkQueue(for: idle)
        step("an agent that is not working: no queue", model.queued[idle.id] == nil)
        QueueProbe.injected = [:]
        model.putInComposer("first", pane: "px")
        model.putInComposer("second", pane: "px")
        step("a second pull goes after the first, on its own line", model.drafts["px"]?.text == "first\nsecond" && model.composerResets["px"] == 2)
        print("snapshot-queued: \(failures == 0 ? "PASS" : "FAIL x\(failures)"), written to \(dir)")
        exit(failures == 0 ? 0 : 1)
    }
}
