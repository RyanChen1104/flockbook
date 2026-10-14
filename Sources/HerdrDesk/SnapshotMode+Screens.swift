import AppKit
import SwiftUI

/// Offscreen check that Overview, Needs you and Search keep their content in the centred screen column
/// (`--test-screencolumn`, `--light` for the light pictures). Windows 1200 and 1440 wide, and a 2560 full-screen layout.
extension ContentTests {
    static func screenColumn() async {
        var failures = 0
        func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("screencolumn-test: \(n) \(ok ? "ok" : "FAIL")") }

        var seen: [String: (CGRect, CGRect)] = [:]
        ScreenColumn.probe = { seen[$0] = ($1, $2) }
        let screens: [(Screen, String)] = [(.overview, "overview"), (.inbox, "needs-you"), (.search, "search")]
        let sizes: [(NSSize, Bool)] = [(NSSize(width: 1200, height: 800), false), (NSSize(width: 1440, height: 900), false),
                                       (NSSize(width: 2560, height: 1440), true)]
        for (size, full) in sizes {
            let model = AppModel(store: .preview)
            let host = NSHostingView(rootView: RootView(flat: false).environment(model).frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            let win = OffscreenWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            WindowChrome.apply(win)
            win.contentView = host; win.setFrameOrigin(NSPoint(x: -4000, y: -3000)); win.orderFrontRegardless()
            if full { ChromeTests.emulateFullScreen(win, model, true) }
            let tag = full ? "\(Int(size.width))-full" : "\(Int(size.width))"
            for (screen, name) in screens {
                seen[name] = nil
                model.screen = screen
                try? await Task.sleep(for: .seconds(1.2))
                guard let (col, area) = seen[name], col.width > 0, area.width > 0 else {
                    step("\(tag) \(name): column reported", false); continue
                }
                // Centred in the detail area, at most ScreenColumn.width; as wide as the column allows when there is room.
                // Search reports its first row, which sits inside the list's own row insets.
                let room = area.width > ScreenColumn.width + 1, slack: CGFloat = name == "search" ? 60 : 1
                step("\(tag) \(name): column \(Int(col.minX))..\(Int(col.maxX)) (\(Int(col.width))) centred in area \(Int(area.minX))..\(Int(area.maxX)) (\(Int(area.width)))",
                     abs(col.midX - area.midX) < 1.5 && col.width <= ScreenColumn.width + 0.5
                     && (room ? col.width > ScreenColumn.width - slack : col.width > area.width - slack))
                capture(win, to: "\(dir)/screen-\(name)-\(tag).png")
            }
            if full { ChromeTests.emulateFullScreen(win, model, false) }
            win.orderOut(nil)
        }

        // The whole detail width scrolls: a wheel over the side margin (outside the column) moves the content.
        let model = AppModel(store: .previewDense)
        let size = NSSize(width: 1440, height: 760)
        let host = NSHostingView(rootView: RootView(flat: false).environment(model).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let win = OffscreenWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        WindowChrome.apply(win)
        win.contentView = host; win.setFrameOrigin(NSPoint(x: -4000, y: -3000)); win.orderFrontRegardless()
        for (screen, name) in screens {
            seen[name] = nil
            model.screen = screen
            try? await Task.sleep(for: .seconds(1.2))
            guard let (col, area) = seen[name] else { step("wheel \(name): column reported", false); continue }
            let x = area.minX + max(8, (col.minX - area.minX) / 2)   // middle of the left margin
            let p = NSPoint(x: x, y: host.bounds.midY)
            let hit = host.hitTest(host.convert(p, to: host.superview))
            guard let sv = hit?.enclosingScrollView, sv.frame.width >= area.width - 2 else {
                step("wheel \(name): margin x \(Int(x)) is inside a full-width scroll view (\(hit.map { "\(type(of: $0))" } ?? "no view"), width \(Int(hit?.enclosingScrollView?.frame.width ?? 0)))", false)
                continue
            }
            let y0 = sv.contentView.bounds.origin.y
            let scrollable = (sv.documentView?.frame.height ?? 0) > sv.contentView.bounds.height + 20
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0),
               let e = NSEvent(cgEvent: cg) { hit?.scrollWheel(with: e) }
            try? await Task.sleep(for: .milliseconds(600))
            let y1 = sv.contentView.bounds.origin.y
            step("wheel \(name): over the margin (x \(Int(x)), column from \(Int(col.minX))) \(scrollable ? "scrolls \(Int(y0)) -> \(Int(y1))" : "is in the scroll view (content fits, nothing to scroll)")",
                 scrollable ? y1 > y0 + 10 : true)
            if scrollable { capture(win, to: "\(dir)/screen-\(name)-scrolled.png") }
        }
        win.orderOut(nil)

        // The conversation too: its scroll view spans the detail width (rows stay in the reading column), so the soft
        // scroll edge under the tab island covers the whole top band, not a column-wide rectangle. Captures cannot show the
        // soft edge itself: this checks the scroll view's width and that the margin scrolls it.
        let cmodel = AppModel(store: .preview)
        let chost = NSHostingView(rootView: RootView(flat: false).environment(cmodel).frame(width: size.width, height: size.height))
        chost.frame = NSRect(origin: .zero, size: size)
        let cwin = OffscreenWindow(contentRect: chost.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        WindowChrome.apply(cwin)
        cwin.contentView = chost; cwin.setFrameOrigin(NSPoint(x: -4000, y: -3000)); cwin.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(2))
        let detail = ChromeProbe.detail
        let cx = detail.minX + 24
        let chit = chost.hitTest(chost.convert(NSPoint(x: cx, y: chost.bounds.midY), to: chost.superview))
        if let sv = chit?.enclosingScrollView {
            step("conversation: scroll view \(Int(sv.frame.width)) wide (under the floating sidebar too), detail \(Int(detail.width)); margin x \(Int(cx)) inside it",
                 sv.frame.width >= detail.width - 2)
            print("screencolumn-test: conversation scroll view \(type(of: sv)) frame \(sv.frame) in window \(sv.convert(sv.bounds, to: nil)), document \(sv.documentView?.frame.size ?? .zero), clip \(sv.contentView.bounds)")
            let y0 = sv.contentView.bounds.origin.y
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 300, wheel2: 0, wheel3: 0),
               let e = NSEvent(cgEvent: cg) { chit?.scrollWheel(with: e) }
            try? await Task.sleep(for: .milliseconds(600))
            let y1 = sv.contentView.bounds.origin.y
            let fits = (sv.documentView?.frame.height ?? 0) <= sv.contentView.bounds.height
            step("conversation: wheel over the margin \(fits ? "is in the scroll view (content fits)" : "scrolls up (\(Int(y0)) -> \(Int(y1)))")", fits || y1 < y0 - 10)
            capture(cwin, to: "\(dir)/screen-conversation-under-island.png")
        } else {
            step("conversation: margin x \(Int(cx)) is inside the conversation scroll view (\(chit.map { "\(type(of: $0))" } ?? "no view"))", false)
        }
        cwin.orderOut(nil)
        ScreenColumn.probe = nil
        print("screencolumn-test: pictures in \(dir)/screen-{overview,needs-you,search}-{1200,1440,2560-full,scrolled}.png")
        print("screencolumn-test: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        NSApp.terminate(nil)
    }
}
