import AppKit
import SwiftUI

extension ContentTests {
    /// Moving an intermediate ancestor places the row without changing its immediate parent's or document's frame.
    /// Compensation must happen synchronously in that placement, before a fallback task can run.
    static func anchorPlacement() -> Bool {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 4000))
        let outer = NSView(frame: NSRect(x: 0, y: 800, width: 400, height: 2000))
        let inner = NSView(frame: NSRect(x: 0, y: 100, width: 400, height: 1000))
        let probe = AnchorProbe.Probe(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        let tracker = ConversationView.BottomTracker()
        tracker.atBottom = false
        probe.tracker = tracker; probe.key = "anchor"
        inner.addSubview(probe); outer.addSubview(inner); doc.addSubview(outer); scroll.documentView = doc
        let win = OffscreenWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = scroll; win.orderFrontRegardless()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 600)); scroll.reflectScrolledClipView(scroll.contentView)
        let top = probe.convert(probe.bounds, to: doc).minY - ConversationView.listPadding
        let before = scroll.contentView.bounds.minY
        tracker.anchor = ("anchor", top, before, Date().addingTimeInterval(30))
        outer.setFrameOrigin(NSPoint(x: 0, y: outer.frame.minY + 120))
        let moved = scroll.contentView.bounds.minY - before
        let ok = abs(moved - 120) < 0.5
        print("churn-test: intermediate ancestor placement compensates before the next frame (\(Int(moved)) pt, want 120) \(ok ? "ok" : "FAIL")")
        win.contentView = nil; win.orderOut(nil)
        return ok
    }
}
