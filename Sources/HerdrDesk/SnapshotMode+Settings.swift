import AppKit
import CoreImage
import HerdrKit
import SwiftUI

/// The settings form (the Settings page's content) in a window of its own, offscreen, in every look it must survive:
///   .build/debug/HerdrDesk --snapshot-settings <dir>
/// -> <dir>/settings-<glass>-<light|dark>.png for Glass, Subtle and Opaque, and settings-reduce-<light|dark>.png
/// (Reduce Transparency, through a stand-in flag). Offscreen there is no desktop and a behind-window blur samples
/// nothing, so each still is composed: a stand-in wallpaper, blurred as the material would, under a capture of the
/// settings form alone. Only this app's own windows are captured, never the screen.
/// Increase Contrast is not rendered here: offscreen, the high-contrast appearances draw the same pixels as
/// the plain ones. The view uses only system colors and controls, so the system handles it.
/// Own settings store (test isolation), no Dock icon, nothing sent anywhere.
extension SnapshotRunner {
    @MainActor static func runSettings(dir: String) async {
        var failures = 0
        let looks: [(String, WindowGlass, Bool)] = [("glass", .full, false), ("subtle", .subtle, false), ("opaque", .off, false), ("reduce", .full, true)]
        for (name, glass, reduce) in looks {
            for dark in [false, true] {
                AppDefaults.store.set(glass.rawValue, forKey: WindowGlass.key)
                // In the app the page sits on the main window's surface (WindowSurface); here its blur is the blurred wallpaper
                // below (offscreen the material view paints solid), so only its tint goes here.
                let surface = reduce ? WindowGlass.off : glass
                let host = NSHostingView(rootView: ZStack {
                    Color(nsColor: .textBackgroundColor).opacity(surface.tint).ignoresSafeArea()
                    SettingsView(reduceTransparency: reduce ? true : nil)
                })
                let size = host.fittingSize
                let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
                win.title = "Flockbook Settings"
                win.titlebarAppearsTransparent = true
                win.isOpaque = false; win.backgroundColor = .clear
                win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                win.contentView = host
                win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(900))
                let path = "\(dir)/settings-\(name)-\(dark ? "dark" : "light").png"
                // The window's own capture must show content: a blank one (no screen-capture permission) is a FAIL,
                // not a wallpaper-only PASS.
                let ink = compose(win, over: wallpaper(win.frame.size, dark: dark), blur: surface != .off, to: path)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                let ok = ink > 0.02 && bytes > 5_000 && size.width >= 480 && size.width <= 600 && size.height > 200 && size.height < 900
                if !ok { failures += 1 }
                print("snapshot-settings: \(name)-\(dark ? "dark" : "light") \(Int(size.width))x\(Int(size.height)) pt, \(bytes / 1024) KB, window \(String(format: "%.1f", ink * 100))% ink \(ok ? "ok" : "FAIL")")
                win.orderOut(nil)
            }
        }
        print("snapshot-settings: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        exit(failures == 0 ? 0 : 1)
    }

    /// The stand-in wallpaper (blurred like the behind-window material when the window is see-through), then the window's
    /// own pixels over it. The capture is of this one window only.
    /// Returns the share of the window capture that is not background (0 = blank capture).
    @discardableResult
    @MainActor private static func compose(_ win: NSWindow, over paper: NSImage, blur: Bool, to path: String) -> Double {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let top = unsafeBitCast(sym, to: Fn.self)(.null, 8, UInt32(win.windowNumber), 1)?.takeRetainedValue(),
              var back = paper.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("snapshot-settings: no window capture (screen-capture permission: \(CGPreflightScreenCaptureAccess()))")
            return 0
        }
        let ink = Pixels(top).ink
        if ink <= 0.02 { print("snapshot-settings: the window capture is blank (screen-capture permission: \(CGPreflightScreenCaptureAccess()))") }
        if blur, let f = CIFilter(name: "CIGaussianBlur") {
            f.setValue(CIImage(cgImage: back).clampedToExtent(), forKey: kCIInputImageKey)
            f.setValue(30, forKey: kCIInputRadiusKey)
            if let out = f.outputImage, let cg = CIContext().createCGImage(out, from: CIImage(cgImage: back).extent) { back = cg }
        }
        let w = top.width, h = top.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return ink }
        let all = CGRect(x: 0, y: 0, width: w, height: h)
        // Rounded like the window, so the corners stay clear.
        ctx.addPath(CGPath(roundedRect: all, cornerWidth: 24 * CGFloat(w) / win.frame.width, cornerHeight: 24 * CGFloat(w) / win.frame.width, transform: nil))
        ctx.clip()
        ctx.draw(back, in: all)
        ctx.resetClip()
        ctx.draw(top, in: all)
        guard let img = ctx.makeImage() else { return ink }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        return ink
    }

    /// A stand-in desktop: soft colour fields with a few hard shapes, so blur and tint both show.
    @MainActor private static func wallpaper(_ size: NSSize, dark: Bool) -> NSImage {
        NSImage(size: size, flipped: false) { r in
            let colors: [NSColor] = dark ? [.systemIndigo, .systemPurple, .systemTeal] : [.systemOrange, .systemPink, .systemTeal]
            NSGradient(colors: colors)?.draw(in: r, angle: 35)
            (dark ? NSColor.black : NSColor.white).withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.width * 0.55, y: r.height * 0.5, width: 180, height: 180)).fill()
            NSColor.systemYellow.setFill()
            NSBezierPath(roundedRect: NSRect(x: 40, y: 60, width: 220, height: 90), xRadius: 20, yRadius: 20).fill()
            return true
        }
    }
}

/// Where the Settings page lies (global frame); zero while it is not shown.
enum SettingsProbe { nonisolated(unsafe) static var page: CGRect = .zero }

extension ChromeTests {
    /// `--test-settings-page`: Settings is a page of the main window, not a window of its own. A Settings row at the foot of
    /// the sidebar opens it in the detail column (a real click), the page fills that column and scrolls (a long Remote
    /// access section), ⌘,'s action opens it from any screen, and another sidebar row leaves it. Offscreen window only;
    /// stills of the page in light and dark, top and scrolled, go to build/snapshots-settings-page/.
    static func runSettingsPageTest() async {
        let dir = "build/snapshots-settings-page"
        let model = AppModel(store: .preview)
        model.remote = RemoteHub.preview(running: true, devices: [(HubDevice(id: "d1", name: "Phone", level: .input), Date(timeIntervalSince1970: 1_790_000_000))], offer: false)
        let size = NSSize(width: 1200, height: 680)
        let host = NSHostingView(rootView: RootView(flat: false).environment(model).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        WindowChrome.apply(win)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(2))
        var failures = 0
        func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("settings-page-test: \(n) \(ok ? "ok" : "FAIL")") }
        // Selects the sidebar list row under the middle of a probed frame, as a click does. A synthetic mouse click selects a
        // List row only in a key window, which a headless run never has: the table row at that point is selected instead.
        func click(_ r: CGRect) async {
            guard let frame = win.contentView?.superview else { return }
            let p = NSPoint(x: r.midX, y: frame.bounds.height - r.midY)
            var v = frame.hitTest(p)
            while let cur = v, !(cur is NSTableView) { v = cur.superview }
            if let table = v as? NSTableView {
                let row = table.row(at: table.convert(p, from: nil))
                if row >= 0 { table.selectRowIndexes([row], byExtendingSelection: false) }
            }
            try? await Task.sleep(for: .milliseconds(600))
        }

        // The row: below every workspace row, at the foot of the sidebar panel.
        let row = ChromeProbe.rows["Settings"] ?? .zero
        let lastRow = model.store.workspaces.compactMap { ChromeProbe.rows["title:\($0.id)"]?.maxY }.max() ?? 0
        let panel = ChromeProbe.panel
        step("Settings row at the foot of the sidebar (row y \(Int(row.minY))..\(Int(row.maxY)), last workspace \(Int(lastRow)), panel bottom \(Int(panel.maxY)))",
             row.width > 0 && row.minY > lastRow && panel.maxY - row.maxY < 24)
        step("no page before it is chosen (\(SettingsProbe.page))", SettingsProbe.page == .zero)
        await click(row)
        step("a click opens the Settings page (\(model.screen))", model.screen == .settings)
        try? await Task.sleep(for: .milliseconds(600))
        let page = SettingsProbe.page, detail = ChromeProbe.detail
        step("the page fills the detail column (page \(page.integral), detail \(detail.integral))",
             page.width > 0 && abs(page.minX - detail.minX) < 2 && abs(page.maxX - detail.maxX) < 2 && page.height > detail.height - 40)

        // It scrolls: the page is taller than the column (with the remote section, even here); a wheel over it moves it.
        func scrollViews(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollViews) }
        let p = NSPoint(x: page.midX, y: page.midY)
        let hit = host.hitTest(host.convert(NSPoint(x: p.x, y: host.isFlipped ? p.y : host.bounds.height - p.y), to: host.superview))
        if let sv = hit?.enclosingScrollView {
            let shown = sv.contentView.bounds.height, content = sv.documentView?.frame.height ?? 0
            ContentTests.capture(win, to: "\(dir)/settings-page-light.png")
            let y0 = sv.contentView.bounds.origin.y
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -400, wheel2: 0, wheel3: 0),
               let e = NSEvent(cgEvent: cg) { hit?.scrollWheel(with: e) }
            try? await Task.sleep(for: .milliseconds(600))
            let y1 = sv.contentView.bounds.origin.y
            step("the page scrolls: shows \(Int(shown)) of \(Int(content)) pt, wheel \(Int(y0)) -> \(Int(y1))", sv.verticalScrollElasticity != .none && y1 > y0 + 30)
            ContentTests.capture(win, to: "\(dir)/settings-page-light-scrolled.png")
            win.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(600))
            ContentTests.capture(win, to: "\(dir)/settings-page-dark-scrolled.png")
            sv.contentView.scroll(to: .zero); sv.reflectScrolledClipView(sv.contentView)
            try? await Task.sleep(for: .milliseconds(600))
            ContentTests.capture(win, to: "\(dir)/settings-page-dark.png")
            win.appearance = nil
        } else { step("a scroll view under the page (\(hit.map { "\(type(of: $0))" } ?? "no view"))", false) }

        // Another row leaves the page.
        await click(ChromeProbe.rows["Overview"] ?? .zero)
        step("Overview row leaves the page (\(model.screen), page \(SettingsProbe.page))", model.screen == .overview && SettingsProbe.page == .zero)
        // ⌘, (the app menu's Settings… calls this) from the tab screen, then a workspace row returns to the agent view.
        model.screen = .tab
        model.showSettings(); try? await Task.sleep(for: .milliseconds(600))
        step("⌘, opens the page from the tab screen (\(model.screen))", model.screen == .settings && SettingsProbe.page.width > 0)
        if let ws = model.workspace, let title = ChromeProbe.rows["title:\(ws.id)"] {
            await click(title)
            step("the current workspace's row returns to its tab (\(model.screen))", model.screen == .tab)
        } else { step("a workspace row to click", false) }
        print("settings-page-test: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        NSApp.terminate(nil)
    }
}
