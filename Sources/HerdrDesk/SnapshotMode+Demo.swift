import AppKit
import HerdrKit
import SwiftUI

/// README / website stills from the live demo session (`scripts/demo-seed.sh`):
///   env -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_ENV \
///     timeout -k 5 60 .build/debug/HerdrDesk --session flockbook-demo --snapshot-demo docs/media [--dark]
/// Read-only: it selects tabs and reads screens, it sends nothing. Offscreen window, no Dock icon, under 60 s;
/// one appearance per run. Each still is checked (its content is on screen) before it is saved; any failure exits 1.
extension SnapshotRunner {
    @MainActor static func runDemo(dir: String, store: HerdrStore) async {
        var failures = 0
        func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("snapshot-demo: \(n) \(ok ? "ok" : "FAIL")") }
        func finish() -> Never {
            print("snapshot-demo: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
            exit(failures == 0 ? 0 : 1)
        }
        guard let name = store.session.name, name.contains("demo") else {
            print("snapshot-demo: needs a named demo session (--session flockbook-demo)"); exit(2)
        }
        let dark = CommandLine.arguments.contains("--dark")
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let suffix = dark ? "dark" : "light"
        let t0 = Date()
        while store.workspaces.count < 6, Date().timeIntervalSince(t0) < 10 { try? await Task.sleep(for: .milliseconds(200)) }
        step("\(name): \(store.workspaces.count) workspaces (want >= 6)", store.workspaces.count >= 6)
        guard store.workspaces.count >= 6 else { finish() }

        var appeared = false
        QuestionProbe.report = { if case .appeared = $0 { appeared = true } }
        let model = AppModel(store: store)
        let size = NSSize(width: 1280, height: 800)
        let host = NSHostingView(rootView: RootView(flat: false).environment(model).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        WindowChrome.apply(win)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()

        func find(_ ws: String, _ tab: String) -> (Workspace, Tab)? {
            guard let w = store.workspaces.first(where: { $0.label == ws }), let t = w.tabs.first(where: { $0.label == tab }) else { return nil }
            return (w, t)
        }
        func open(_ ws: String, _ tab: String) -> Tab? {
            guard let (w, t) = find(ws, tab) else { step("tab \(ws) / \(tab) exists", false); return nil }
            model.select(tab: t, in: w)
            return t
        }
        func items(_ t: Tab?) -> [Int] { (t?.panes ?? []).map { store.conversation(for: $0.agent?.sessionId).count } }
        /// Waits up to `limit` seconds for `ok`, then a moment more for the layout to settle.
        func wait(_ limit: Double, _ ok: () -> Bool) async -> Bool {
            let start = Date()
            while !ok(), Date().timeIntervalSince(start) < limit { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .milliseconds(600))
            return ok()
        }
        func save(_ shot: String) {
            let path = "\(dir)/\(shot)-\(suffix).png"
            capture(win, to: path)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            step("saved \(path) (\(bytes / 1024) KB)", bytes > 10_000)
        }
        try? await Task.sleep(for: .seconds(1))

        // 1. Sidebar + overview: every workspace and status at a glance.
        model.screen = .overview
        step("overview: tabs in every status", await wait(3) {
            let s = Set(store.workspaces.flatMap(\.tabs).map(\.status)); return s.isSuperset(of: [.blocked, .working, .done, .idle])
        })
        save("overview")

        // 2. Conversation: markdown, a code block, a table, tool chips.
        let rank = open("Quarry", "ranking")
        let rankOK = await wait(6) { items(rank).allSatisfy { $0 >= 5 } }
        step("conversation: log loaded \(items(rank))", rankOK)
        save("conversation")

        // 3. Question card (Claude's picker, read from the pane's screen).
        appeared = false
        _ = open("Lighthouse", "getting started")
        step("question card appears", await wait(8) { appeared })
        save("question")

        // 4. Approval card (permission prompt on screen + pending tool call in the log).
        let deploy = open("Harbor", "deploy")
        let deployPane = deploy?.panes.first?.id ?? ""
        step("approval card: prompt seen on \(deployPane)", await wait(8) { model.promptVisible.contains(deployPane) && model.hasPending(deploy!.panes[0]) })
        save("approval")

        // 5. Needs-you list.
        model.screen = .inbox
        step("needs-you: \(model.allBlocked.count) tabs", await wait(3) { model.allBlocked.count >= 2 })
        save("needs-you")

        // 6. Split panes in one tab.
        let pricing = open("Orchard", "pricing")
        let splitOK = await wait(6) { (pricing?.panes.count ?? 0) >= 2 && items(pricing).allSatisfy { $0 > 0 } }
        step("split: \(pricing?.panes.count ?? 0) panes, logs \(items(pricing))", splitOK)
        save("split")

        // 7. Embedded terminal sheet (a separate window: composited onto the main one).
        _ = open("Orchard", "cart drawer")
        try? await Task.sleep(for: .seconds(1))
        model.showTerminal = true
        step("terminal sheet is up", await wait(5) { win.attachedSheet != nil })
        try? await Task.sleep(for: .seconds(1.5))   // first frames reach the terminal
        if let sheet = win.attachedSheet { captureWithSheet(win, sheet, to: "\(dir)/terminal-\(suffix).png") }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: "\(dir)/terminal-\(suffix).png")[.size] as? Int) ?? 0
        step("saved \(dir)/terminal-\(suffix).png (\(bytes / 1024) KB)", bytes > 10_000)
        model.showTerminal = false

        print("snapshot-demo: \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        finish()
    }

    @MainActor private static func capture(_ win: NSWindow, to path: String) { ContentTests.capture(win, to: path) }

    /// The window server draws a sheet as its own window: grab both and draw the sheet where it sits on the window.
    @MainActor private static func captureWithSheet(_ win: NSWindow, _ sheet: NSWindow, to path: String) {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let grab = unsafeBitCast(sym, to: Fn.self)
        guard let base = grab(.null, 8, UInt32(win.windowNumber), 1)?.takeRetainedValue(),
              let top = grab(.null, 8, UInt32(sheet.windowNumber), 1)?.takeRetainedValue() else { return }
        let k = CGFloat(base.width) / win.frame.width
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        // Both frames are in screen points with a bottom-left origin, as is the context.
        let x = (sheet.frame.minX - win.frame.minX) * k, y = (sheet.frame.minY - win.frame.minY) * k
        ctx.draw(top, in: CGRect(x: x, y: y, width: CGFloat(top.width), height: CGFloat(top.height)))
        guard let img = ctx.makeImage() else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
