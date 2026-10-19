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
        let tooLong = "This queued text is too long or has spaces or blank lines that the agent's input box does not show, so Flockbook cannot check it exactly. Edit it in the agent's terminal. Nothing was sent."
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
            step("\(name): the window stays off every screen", await shot(queue: model.queued[pane.id], draft: model.drafts[pane.id],
                 agent: pane.agent?.name ?? "claude", dark: dark, path: "\(dir)/queued-\(name)-\(dark ? "dark" : "light").png"))
        }
        // A pull QueuePull refused before any key (too long to check exactly): the app's notice; the queue stays.
        for dark in [false, true] {
            let q = QueuedInput(agent: "claude", items: [String(repeating: "Also run the lint step before you commit, ", count: 3) + "and fix what fails."], pullable: true)
            step("refused: the window stays off every screen",
                 await shot(queue: q, draft: nil, agent: "claude", dark: dark, notice: tooLong, path: "\(dir)/queued-refused-\(dark ? "dark" : "light").png"))
        }

        // A queued bubble ends where the user's bubbles end, at every reading width, text size and pane width.
        for width in ReadingWidth.allCases {
            for size in ReadingSize.allCases {
                for pane in [CGFloat(700), 1400] {
                    let e = await edges(width: width, size: size, pane: pane)
                    step("aligned: \(width.rawValue) \(size.rawValue) in \(Int(pane)): queued, composer and approval card end at the user's bubble (\(e.user) vs \(e.queued), \(e.composer), \(e.card)), off every screen",
                         e.user > 0 && [e.queued, e.composer, e.card].allSatisfy { abs($0 - e.user) < 0.5 } && e.away)
                }
            }
        }
        AppDefaults.store.set(ReadingWidth.medium.rawValue, forKey: ReadingWidth.key)
        AppDefaults.store.set(ReadingSize.m.rawValue, forKey: ReadingSize.key)

        let model = AppModel(store: store)
        QueueProbe.injected = [idle.id: QueuedInput(agent: "claude", items: two, pullable: true)]
        model.queued[idle.id] = QueuedInput(agent: "claude", items: two, pullable: true)
        await model.checkQueue(for: idle)
        step("an agent that is not working: no queue", model.queued[idle.id] == nil)
        QueueProbe.injected = [:]
        model.putInComposer("first", pane: "px")
        model.putInComposer("second", pane: "px")
        step("a second pull goes after the first, on its own line", model.drafts["px"]?.text == "first\nsecond" && model.composerResets["px"] == 2)

        // A pull kept its text, and the app quit before the composer had it: the pane's next check puts it there.
        // r2 P1-2: the composer's draft lives in memory only, so the kept text stays on disk until that composer sends.
        let texts = MemoryPulledStore()
        _ = texts.keep(PulledText(id: "k1", pane: idle.id, device: PulledText.mac, text: "if ready:\n    run()"))
        _ = texts.keep(PulledText(id: "k2", pane: idle.id, device: "phone-1", text: "the phone's"))
        let back = AppModel(store: store)
        back.pulledTexts = texts
        back.pulling = [idle.id]
        await back.checkQueue(for: idle)
        step("a kept text waits while a pull of the pane runs", back.drafts[idle.id] == nil && back.pulledTexts.all.count == 2)
        back.pulling = []
        await back.checkQueue(for: idle)
        step("a kept text goes into the composer, exactly", back.drafts[idle.id]?.text == "if ready:\n    run()")
        step("r2 P1-2: still kept after it is in the composer (the draft is memory only)", back.pulledTexts.all.map(\.id) == ["k1", "k2"])
        await back.checkQueue(for: idle)
        step("in the composer once, not again on the next check", back.drafts[idle.id]?.text == "if ready:\n    run()")
        let restarted = AppModel(store: store)
        restarted.pulledTexts = texts
        await restarted.checkQueue(for: idle)
        step("r2 P1-2: a quit before the send: the next start puts it in the composer again", restarted.drafts[idle.id]?.text == "if ready:\n    run()")
        var typed: [String] = []
        restarted.sendHook = { pane, text in typed.append("\(pane) \(text)"); return true }
        let ok = await restarted.deliver("if ready:\n    run()", pane: idle.id, kind: "claude")
        step("r2 P1-2: the composer sent it: the kept text goes, the phone's stays", ok && typed.count == 1 && texts.all.map(\.id) == ["k2"])

        // r2 P1-3: one pull or send per pane at a time, for the whole of it (the Mac's composer and the hub's send).
        typed = []
        restarted.busy = [idle.id]
        let refused = await restarted.deliver("M", pane: idle.id, kind: "claude")
        step("r2 P1-3: a send while a pull of the pane runs: refused, nothing typed", !refused && typed.isEmpty)
        let hub = AppHubBackend(model: restarted)
        let viaHub = await hub.send(pane: idle.id, text: "M", images: [], agent: idle.agent!, allowed: { true })
        step("r2 P1-3: a phone's send while the pane is busy: refused, nothing typed (\(viaHub))", viaHub == .changed && typed.isEmpty)
        restarted.busy = []
        restarted.sendHook = { pane, text in
            typed.append("\(pane) \(text)")
            return restarted.busy.contains(pane)   // the lock is held while the keys go out
        }
        let held = await restarted.deliver("N", pane: idle.id, kind: "claude")
        let heldHub = await hub.send(pane: idle.id, text: "O", images: [], agent: idle.agent!, allowed: { true })
        step("r2 P1-3: a send holds the pane's lock while it types, and lets it go after", held && heldHub == .sent && restarted.busy.isEmpty)
        print("snapshot-queued: \(failures == 0 ? "PASS" : "FAIL x\(failures)"), written to \(dir)")
        exit(failures == 0 ? 0 : 1)
    }

    /// The right edges (global x) of a user bubble in the conversation's reading column and of what goes under it (a queued
    /// bubble, the composer, an approval card in the composer's place), in a pane `pane` wide, and whether the window
    /// touched no screen. Draws nothing to disk.
    @MainActor private static func edges(width: ReadingWidth, size: ReadingSize, pane: CGFloat) async
        -> (user: CGFloat, queued: CGFloat, composer: CGFloat, card: CGFloat, away: Bool) {
        AppDefaults.store.set(width.rawValue, forKey: ReadingWidth.key)
        AppDefaults.store.set(size.rawValue, forKey: ReadingSize.key)
        var user = CGFloat(0), queued = CGFloat(0), composer = CGFloat(0), card = CGFloat(0)
        QueueProbe.bubble = { queued = $0.maxX }
        defer { QueueProbe.bubble = nil }
        let view = VStack(spacing: 0) {
            Spacer()
            HStack {
                Spacer(minLength: min(size.column * 0.2, 120))
                UserBubble(text: "The build fails on main. Please fix it.", size: size)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { user = $0.maxX }
            }
            .readingColumn(size, width)
            QueuedStrip(queue: QueuedInput(agent: "claude", items: ["Also run the lint step."], pullable: true), canPull: true, pulling: false, onPull: {})
            ComposerView(agentName: "claude", draft: ComposerDraft(), onSend: { _ in })
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { composer = $0.maxX }
                .inputColumn()
            ApprovalCard(request: PermissionRequest(title: "claude wants to run a build", command: "swift build", toolUseId: "toolu_a"),
                         agentName: "claude", canRespond: true, onAllow: {}, onDeny: {}, onOpen: {})
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { card = $0.maxX }
                .inputColumn()
        }
        .environment(\.flatGlass, true)
        .frame(width: pane, height: 900)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: pane, height: 900)
        let win = OffscreenWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        var away = true
        func check() { away = away && !NSScreen.screens.contains(where: { $0.frame.intersects(win.frame) }) }
        win.contentView = host; win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless(); check()
        for _ in 0..<3 { try? await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded(); check() }
        win.orderOut(nil)
        func half(_ x: CGFloat) -> CGFloat { (x * 2).rounded() / 2 }
        return (half(user), half(queued), half(composer), half(card), away)
    }

    /// One still: the last message, the queue strip and the composer, as PaneView stacks them. Waits with Task.sleep, not
    /// a nested run loop: the composer sizes itself in a main-queue block that a nested run loop would never run.
    @MainActor private static func shot(queue: QueuedInput?, draft: ComposerDraft?, agent: String, dark: Bool, notice: String? = nil, path: String) async -> Bool {
        let size = NSSize(width: 900, height: 420)
        // The bottom of a pane: the last reply, the queue strip and the composer. (The conversation's scroll view does
        // not draw in an offscreen capture, so the reply is a plain bubble here, in the reading column as the conversation lays it out.)
        let view = ZStack(alignment: .bottom) {
            Color(nsColor: .textBackgroundColor)
            VStack(spacing: 0) {
                Spacer()
                HStack {
                    Spacer(minLength: 120)
                    UserBubble(text: "The build fails on main. Please fix it.", size: .m)
                }
                .readingColumn(.m, .medium).padding(.bottom, 14)
                if let queue { QueuedStrip(queue: queue, canPull: true, pulling: false, onPull: {}) }
                ComposerView(agentName: agent, draft: draft ?? ComposerDraft(), onSend: { _ in })
                    .inputColumn()
            }
        }
        .overlay(alignment: .top) { if let notice { NoticeCapsule(text: notice).padding(.top, 16).padding(.horizontal, 24) } }
        .environment(\.flatGlass, true).environment(\.colorScheme, dark ? .dark : .light)
        .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let win = OffscreenWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // After the show and each layout (SwiftUI can resize it), the frame must touch no screen.
        var away = true
        func check() { away = away && !NSScreen.screens.contains(where: { $0.frame.intersects(win.frame) }) }
        win.contentView = host; win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless(); check()
        for _ in 0..<12 { try? await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); check() }
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        win.orderOut(nil)
        return away
    }
}
