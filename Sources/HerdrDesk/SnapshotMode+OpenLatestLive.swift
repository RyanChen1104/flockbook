import AppKit
import HerdrKit
import SwiftUI

/// Live, read-only check (`--test-open-latest-live`, a named session and `--read-only` only): the whole RootView over real
/// logs, a full-screen-sized window. Each agent tab opens at its newest message; the window hidden and shown stays there.
/// Sends nothing to herdr (tab switches are local).
extension ContentTests {
    static func openLatestLive(_ args: [String]) async {
        var failures = 0
        func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("open-latest-live: \(n) \(ok ? "ok" : "FAIL")") }
        let session = HerdrSession.fromLaunch(arguments: args, environment: ProcessInfo.processInfo.environment)
        guard session.name != nil, args.contains("--read-only") else {
            print("open-latest-live: usage: HerdrDesk --session <name> --read-only --test-open-latest-live (named session only)"); exit(2)
        }
        // RootView starts the notifier on appear: a check must never ask for notification permission or post one.
        step("notifications off in checks", Notifier.shared.quiet)
        let store = HerdrStore(session: session)
        let model = AppModel(store: store)
        store.start()
        let size = NSSize(width: 1512, height: 945)
        let host = NSHostingView(rootView: RootView().environment(model).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let win = OffscreenWindow(contentRect: host.frame, styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        win.contentView = host; win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()

        func scrolls(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrolls) }
        func range(_ s: NSScrollView) -> CGFloat { (s.documentView?.frame.height ?? 0) + s.contentInsets.top + s.contentInsets.bottom - s.bounds.height }
        func conversation() -> NSScrollView? { scrolls(host).filter { range($0) > 20 }.max { $0.bounds.width < $1.bounds.width } }
        func gap() -> CGFloat? {
            guard let s = conversation(), let d = s.documentView else { return nil }
            let visibleBottom = s.contentView.bounds.origin.y + s.contentView.bounds.height
            return d.isFlipped ? d.frame.height + s.contentInsets.bottom - visibleBottom : s.contentView.bounds.origin.y + s.contentInsets.bottom
        }
        func show(_ g: CGFloat?) -> String { g.map { String(format: "%.0f", $0) } ?? "-" }
        func inset() -> String { conversation().map { "insets \(Int($0.contentInsets.top))/\(Int($0.contentInsets.bottom)) doc \(Int($0.documentView?.frame.height ?? 0))" } ?? "no scroll" }

        while store.workspaces.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        let tabs = store.workspaces.flatMap { w in w.tabs.map { (w, $0) } }.filter { $0.1.panes.contains { $0.agent?.sessionId != nil } }
        print("open-latest-live: \(tabs.count) agent tabs")
        for (n, (w, t)) in tabs.enumerated() {
            model.select(tab: t, in: w)
            try? await Task.sleep(for: .seconds(0.5))
            let g1 = gap()
            try? await Task.sleep(for: .seconds(2.5))
            let g2 = gap()
            let count = t.panes.compactMap { $0.agent }.map { store.conversation(for: $0.sessionId).count }
            step("tab \(n) \(t.label) rows \(count): gap \(show(g1)) -> \(show(g2)) (\(inset()))", g2.map { $0 < 4 } ?? true)
            capture(win, to: "\(dir)/open-latest-live-\(n).png")
        }
        win.orderOut(nil)
        try? await Task.sleep(for: .seconds(1))
        win.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1.5))
        step("background: back (gap \(show(gap())), \(inset()))", gap().map { $0 < 4 } ?? true)
        win.orderOut(nil)
        print("open-latest-live: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        exit(failures == 0 ? 0 : 1)
    }
}
