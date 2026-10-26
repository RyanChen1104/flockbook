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
        let focused = CommandLine.arguments.contains("latency-probe-only")
        let blockMilliseconds = focused ? min(2000, max(0, Int(ProcessInfo.processInfo.environment["TAB_OVERFLOW_BLOCK_MAIN_MS"] ?? "0") ?? 0)) : 0
        TabProbe.selectionDelayMilliseconds = min(4000, max(200, Int(ProcessInfo.processInfo.environment["TAB_OVERFLOW_SCROLL_DELAY_MS"] ?? "200") ?? 200))
        TabProbe.traceSelection = ProcessInfo.processInfo.environment["TAB_OVERFLOW_TRACE"] != nil
        TabProbe.measureSelection = true
        if TabProbe.traceSelection { print("tab-overflow: selection debounce \(TabProbe.selectionDelayMilliseconds) ms, trace enabled") }
        var failures = 0
        func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("tab-overflow: \(n) \(ok ? "ok" : "FAIL")") }
        let dir = "build/snapshots-tab-overflow"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func f(_ r: CGRect) -> String { String(format: "x %.0f...%.0f w %.0f", r.minX, r.maxX, r.width) }
        func selectedTabVisible(_ tab: Tab, in workspace: Workspace, model: AppModel, host: IslandHost, tag: String) async -> Bool {
            TabProbe.beginSelection(tab.id, model: model, host: host)
            let start = TabProbe.selectionTiming!.start
            model.select(tab: tab, in: workspace)
            // Focused control verifies that normal-debounce slow placement warns without failing valid geometry.
            func blockMainActor() { Thread.sleep(forTimeInterval: Double(blockMilliseconds) / 1000) }
            if blockMilliseconds > 0 { blockMainActor() }
            // Keep the original observation interval, so an old in-view probe cannot pass before selection updates.
            // A delayed selection task may still be pending then: wait for its actual placed result, with a deadline.
            try? await Task.sleep(for: .milliseconds(1200))
            let ready = await CheckWait.until(.seconds(5) - start.duration(to: .now)) {
                let pill = TabProbe.pills[tab.id] ?? .zero, island = TabProbe.island
                return island.width > 0 && pill.width > 0
                    && pill.minX >= island.minX - 0.5 && pill.maxX <= island.maxX + 0.5
            }
            let timing = TabProbe.selectionTiming!
            func milliseconds(_ duration: Duration) -> Double {
                Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
            }
            let elapsed = timing.visibleAfter.map(milliseconds)
            if TabProbe.selectionDelayMilliseconds == 200, let elapsed, elapsed > 1200 {
                print(String(format: "tab-overflow: WARN selected tab took %.3f ms (> 1200 ms): %@", elapsed, tag))
            }
            if TabProbe.traceSelection {
                let row: [String: Any] = ["case": tag, "tab": tab.id, "debounce_ms": TabProbe.selectionDelayMilliseconds,
                    "visible": ready && elapsed != nil, "visible_ms": elapsed.map { $0 as Any } ?? NSNull(),
                    "task_ms": timing.taskAfter.map { milliseconds($0) as Any } ?? NSNull(),
                    "scrolled": timing.scrolled, "initially_visible": timing.initiallyVisible]
                if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8) {
                    print("tab-selection-timing: \(json)")
                }
            }
            TabProbe.selectionTiming = nil
            return ready && elapsed != nil
        }
        func picture(_ win: NSWindow, _ file: String) {
            typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
                  let img = unsafeBitCast(sym, to: Fn.self)(.null, 8, UInt32(win.windowNumber), 1)?.takeRetainedValue() else { return }
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(file).png"))
        }
        for count in focused ? [40] : [20, 40] {
            let model = AppModel(store: .previewManyTabs(count))
            let size = NSSize(width: 1200, height: 800)
            let host = NSHostingView(rootView: AnyView(RootView(flat: false).environment(model).frame(width: size.width, height: size.height)))
            host.frame = NSRect(origin: .zero, size: size)
            let win = OffscreenWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            WindowChrome.apply(win)
            win.contentView = host; win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(1.5))
            guard let ws = model.store.workspaces.first, let first = ws.tabs.first, let last = ws.tabs.last else { step("\(count) tabs: store", false); continue }
            for w in focused ? [1600] : [1200, 1600, 2000] {
                for side in focused ? [false] : [true, false] {
                    let tag = "\(count) tabs, \(w) wide, sidebar \(side ? "on" : "off")"
                    host.rootView = AnyView(RootView(flat: false).environment(model).frame(width: CGFloat(w), height: 800))
                    win.setContentSize(NSSize(width: CGFloat(w), height: 800))
                    model.setSidebarVisibility(side ? .all : .detailOnly)
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
                    let windowedReady = await selectedTabVisible(last, in: ws, model: model, host: .toolbar, tag: "\(tag) windowed")
                    let pill = TabProbe.pills[last.id] ?? .zero, island = TabProbe.island
                    step("\(tag) windowed: last tab \(f(pill)) inside island \(f(island))",
                         windowedReady && pill.width > 0 && pill.minX >= island.minX - 0.5 && pill.maxX <= island.maxX + 0.5)

                    // Full-screen layout at rest: the content copy, where the toolbar laid its items out.
                    model.select(tab: first, in: ws)
                    emulateFullScreen(win, model, true)
                    win.toolbar?.isVisible = false
                    try? await Task.sleep(for: .seconds(1.2))
                    let ci = TabProbe.island, ca = ChromeProbe.fullScreenActions, ct = ChromeProbe.fullScreenToggle
                    step("\(tag) full screen: island \(f(ci)), buttons \(f(ca)), toggle \(f(ct))",
                         ci.width > 0 && ca.width > 0 && ci.maxX <= ca.minX + 1 && ci.minX >= ct.maxX - 1 && ca.maxX <= CGFloat(w))
                    picture(win, "\(count)-\(w)-\(side ? "side" : "noside")-fullscreen")
                    let fullScreenReady = await selectedTabVisible(last, in: ws, model: model, host: .content, tag: "\(tag) full screen")
                    let fp = TabProbe.pills[last.id] ?? .zero, fi = TabProbe.island
                    step("\(tag) full screen: last tab \(f(fp)) inside island \(f(fi))",
                         fullScreenReady && fp.width > 0 && fp.minX >= fi.minX - 0.5 && fp.maxX <= fi.maxX + 0.5)
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
            win.contentView = nil; win.orderOut(nil)
        }
        print("tab-overflow: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        NSApp.terminate(nil)
    }
}
