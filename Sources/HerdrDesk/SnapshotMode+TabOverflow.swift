import AppKit
import HerdrKit
import SwiftUI

extension ChromeTests {
    /// `--test-tab-overflow`: a workspace with many tabs (20, 40) at window widths 1200, 1600, 2000, sidebar shown and hidden,
    /// windowed and in the full-screen layout. The tab island stays inside the room it is given: it is no wider than its
    /// toolbar item, it does not overlap the + / terminal capsule or the sidebar toggle, both end inside the window, no
    /// item falls into the ">>" overflow, and the last tab, once selected, scrolls fully into the island.
    /// Pictures: build/snapshots-tab-overflow/.
    static func runTabOverflowTest() async {
        var failures = 0
        func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("tab-overflow: \(n) \(ok ? "ok" : "FAIL")") }
        let dir = "build/snapshots-tab-overflow"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func f(_ r: CGRect) -> String { String(format: "x %.0f...%.0f w %.0f", r.minX, r.maxX, r.width) }
        func picture(_ win: NSWindow, _ file: String) {
            typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
                  let img = unsafeBitCast(sym, to: Fn.self)(.null, 8, UInt32(win.windowNumber), 1)?.takeRetainedValue() else { return }
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(file).png"))
        }
        for count in [20, 40] {
            let model = AppModel(store: .previewManyTabs(count))
            let size = NSSize(width: 1200, height: 800)
            let host = NSHostingView(rootView: AnyView(RootView(flat: false).environment(model).frame(width: size.width, height: size.height)))
            host.frame = NSRect(origin: .zero, size: size)
            let win = OffscreenWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            WindowChrome.apply(win)
            win.contentView = host; win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(1.5))
            guard let ws = model.store.workspaces.first, let first = ws.tabs.first, let last = ws.tabs.last else { step("\(count) tabs: store", false); continue }
            for w in [1200, 1600, 2000] {
                for side in [true, false] {
                    let tag = "\(count) tabs, \(w) wide, sidebar \(side ? "on" : "off")"
                    host.rootView = AnyView(RootView(flat: false).environment(model).frame(width: CGFloat(w), height: 800))
                    win.setContentSize(NSSize(width: CGFloat(w), height: 800))
                    model.sidebarVisibility = side ? .all : .detailOnly
                    model.select(tab: first, in: ws)
                    try? await Task.sleep(for: .seconds(1.2))

                    // Windowed: the toolbar copy.
                    if let tb = win.toolbar, let row = WindowChrome.toolbarRow(win) {
                        let vis = Set((tb.visibleItems ?? []).map { ObjectIdentifier($0) })
                        let hidden = tb.items.filter { !vis.contains(ObjectIdentifier($0)) && !$0.itemIdentifier.rawValue.contains("Separator") }
                        let drawn = TabProbe.island, toggle = ChromeProbe.toggle
                        step("\(tag) windowed: item \(f(row.island)), island drawn w \(Int(drawn.width)), buttons \(f(row.actions)), toggle \(f(toggle)), hidden items \(hidden.count)",
                             hidden.isEmpty && drawn.width <= row.island.width + 1 && row.island.maxX <= row.actions.minX + 1
                             && row.island.minX >= toggle.maxX - 1 && row.actions.maxX <= CGFloat(w))
                    } else {
                        step("\(tag) windowed: toolbar row measured", false)
                    }
                    picture(win, "\(count)-\(w)-\(side ? "side" : "noside")-windowed")
                    model.select(tab: last, in: ws)
                    try? await Task.sleep(for: .seconds(1.2))
                    let pill = TabProbe.pills[last.id] ?? .zero, island = TabProbe.island
                    step("\(tag) windowed: last tab \(f(pill)) inside island \(f(island))",
                         pill.width > 0 && pill.minX >= island.minX - 0.5 && pill.maxX <= island.maxX + 0.5)

                    // Full-screen layout at rest: the content copy, where the toolbar laid its items out.
                    model.select(tab: first, in: ws)
                    emulateFullScreen(win, model, true)
                    win.toolbar?.isVisible = false
                    try? await Task.sleep(for: .seconds(1.2))
                    let ci = TabProbe.island, ca = ChromeProbe.fullScreenActions, ct = ChromeProbe.fullScreenToggle
                    step("\(tag) full screen: island \(f(ci)), buttons \(f(ca)), toggle \(f(ct))",
                         ci.width > 0 && ca.width > 0 && ci.maxX <= ca.minX + 1 && ci.minX >= ct.maxX - 1 && ca.maxX <= CGFloat(w))
                    picture(win, "\(count)-\(w)-\(side ? "side" : "noside")-fullscreen")
                    model.select(tab: last, in: ws)
                    try? await Task.sleep(for: .seconds(1.2))
                    let fp = TabProbe.pills[last.id] ?? .zero, fi = TabProbe.island
                    step("\(tag) full screen: last tab \(f(fp)) inside island \(f(fi))",
                         fp.width > 0 && fp.minX >= fi.minX - 0.5 && fp.maxX <= fi.maxX + 0.5)
                    // Full screen at rest on a one-tab workspace, then over to the many tabs: the toolbar is hidden
                    // the whole time (as at rest in real full screen), so its layout is the one-tab workspace's.
                    if let small = model.store.workspaces.last, small.id != ws.id {
                        win.toolbar?.isVisible = true
                        model.select(workspace: small.id)
                        try? await Task.sleep(for: .seconds(1.2))
                        let staleIsland = model.toolbarIsland, staleActions = model.toolbarActions
                        win.toolbar?.isVisible = false
                        try? await Task.sleep(for: .seconds(0.5))
                        model.select(workspace: ws.id)
                        model.select(tab: first, in: ws)
                        // Real full screen at rest: the toolbar window is slid away and does not lay its items out again,
                        // so the measured place stays the one-tab island's (owner's shot 10-19). The offscreen toolbar does.
                        try? await Task.sleep(for: .seconds(1.2))
                        model.toolbarIsland = staleIsland; model.toolbarActions = staleActions
                        try? await Task.sleep(for: .seconds(0.6))
                        let si = TabProbe.island, sa = ChromeProbe.fullScreenActions
                        step("\(tag) full screen, from a one-tab workspace (toolbar measured \(f(model.toolbarIsland))): island \(f(si)), buttons \(f(sa))",
                             si.width > 0 && sa.width > 0 && si.maxX <= sa.minX + 1 && si.minX >= ChromeProbe.fullScreenToggle.maxX - 1
                             && sa.maxX <= CGFloat(w))
                        picture(win, "\(count)-\(w)-\(side ? "side" : "noside")-fullscreen-switch")
                    }
                    win.toolbar?.isVisible = true
                    emulateFullScreen(win, model, false)
                }
            }
            win.orderOut(nil)
        }
        print("tab-overflow: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        NSApp.terminate(nil)
    }
}
