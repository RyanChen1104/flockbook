import AppKit
import HerdrKit
import SwiftUI

extension ContentTests {
    /// A file and a screenshot thumbnail (a file promise) dragged onto the composer in the app's own window (split view,
    /// glass cards): AppKit's drag hit test finds a view there that takes them, on the text and beside it.
    static func dragRoute() async {
        AppDefaults.store.set(true, forKey: AppSettings.allowInputKey)
        let model = AppModel(store: .preview)
        let size = NSSize(width: 1200, height: 800)
        let host = NSHostingView(rootView: RootView(flat: false).environment(model).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let win = OffscreenWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        WindowChrome.apply(win)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(2))
        var failures = 0
        func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("dragroute-test: \(n) \(ok ? "ok" : "FAIL")") }
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let tvs = all(win.contentView?.superview ?? host).compactMap { $0 as? ComposerTextView.SubmitTextView }
        step("one composer (\(tvs.count))", tvs.count == 1)
        if let tv = tvs.first {
            let shot = FileManager.default.temporaryDirectory.appendingPathComponent("Screenshot \(UUID().uuidString).png")
            try? Data().write(to: shot)
            let r = tv.convert(tv.visibleRect, to: nil)
            for (place, p) in [("on the text", NSPoint(x: r.midX, y: r.midY)), ("below the text", NSPoint(x: r.midX, y: r.minY - 18))] {
                for (kind, writers) in [("file", [shot as NSURL] as [NSPasteboardWriting]),
                                        ("screenshot thumbnail", [NSFilePromiseProvider(fileType: "public.png", delegate: NoPromise())])] {
                    let fd = FakeDrag(writers: writers, at: p, in: win)
                    DropOutlineProbe.outline = .zero
                    let view = fd.enter()
                    step("\(kind) \(place): taken by \(view.map { "\(type(of: $0))" } ?? "none")", view != nil)
                    try? await Task.sleep(for: .milliseconds(300))
                    step("\(kind) \(place): the outline is the card's edge (\(DropOutlineProbe.outline) vs \(DropOutlineProbe.card))",
                         DropOutlineProbe.outline != .zero && DropOutlineProbe.outline.equalTo(DropOutlineProbe.card))
                    view?.draggingExited(fd)
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            try? FileManager.default.removeItem(at: shot)
            // The drop area behind the card takes no mouse: clicks, selection, scrolling and the context menu still reach
            // the text, by the window's own event routing (hit test, then sendEvent).
            let root = win.contentView?.superview ?? host
            let at = { tv.convert(NSPoint(x: 30, y: tv.visibleRect.midY), to: nil) }
            step("hit test on the text: \(root.hitTest(at()).map { "\(type(of: $0))" } ?? "none")", root.hitTest(at()) === tv)
            func mouse(_ type: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1) {
                guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) else { return }
                if type == .leftMouseDown { NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: e.timestamp,
                                                                                windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 0)!, atStart: false) }
                win.sendEvent(e)
                if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { win.sendEvent(up) }
            }
            // Mouse clicks: a double-click selects a word. The offscreen window is never key: a click on an inactive window
            // only activates it (NSTextView takes no first mouse), so one click goes first.
            mouse(.leftMouseDown, at())
            try? await Task.sleep(for: .milliseconds(300))
            tv.string = "words to select"
            try? await Task.sleep(for: .milliseconds(300))
            let w = tv.convert(NSPoint(x: 8, y: tv.visibleRect.midY), to: nil)
            mouse(.leftMouseDown, w, clicks: 2)
            try? await Task.sleep(for: .milliseconds(300))
            step("a double-click selects a word (\(tv.selectedRange()))", tv.selectedRange() == NSRange(location: 0, length: 5))
            tv.string = (1...40).map { "line \($0)" }.joined(separator: "\n")
            tv.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: tv))
            try? await Task.sleep(for: .milliseconds(600))
            let clip = tv.enclosingScrollView?.contentView
            clip?.scroll(to: .zero); tv.enclosingScrollView?.reflectScrolledClipView(clip!)
            let before = clip?.bounds.origin.y ?? 0
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0) {
                // No window on the event: its window location is the screen one, so the point is given as the window's.
                cg.location = CGPoint(x: at().x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - at().y)
                if let e = NSEvent(cgEvent: cg) { win.sendEvent(e) }
            }
            try? await Task.sleep(for: .milliseconds(400))
            step("scrolling over the text scrolls it (doc \(tv.frame.height) clip \(clip?.bounds.height ?? 0)) (\(before) → \(clip?.bounds.origin.y ?? 0))", (clip?.bounds.origin.y ?? 0) > before)
            let right = NSEvent.mouseEvent(with: .rightMouseDown, location: at(), modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            let hitRight = root.hitTest(at())
            step("a right-click reaches the text, which has its menu", hitRight === tv && right.flatMap { tv.menu(for: $0) } != nil)
        }
        print("dragroute-test: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        exit(failures == 0 ? 0 : 1)
    }

    private final class NoPromise: NSObject, NSFilePromiseProviderDelegate {
        func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType t: String) -> String { "shot.png" }
        func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }
    }
}
