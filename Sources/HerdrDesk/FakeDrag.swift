import AppKit

/// A drag for the checks: AppKit's route without a mouse. The view AppKit's drag hit test finds under `point` for the
/// pasteboard's types gets entered, prepare and perform, as a real drop does.
@MainActor final class FakeDrag: NSObject, @MainActor NSDraggingInfo {
    let pb: NSPasteboard, point: NSPoint, window: NSWindow
    convenience init(urls: [URL], at point: NSPoint, in window: NSWindow) { self.init(writers: urls as [NSURL], at: point, in: window) }
    init(writers: [NSPasteboardWriting], at point: NSPoint, in window: NSWindow) {
        pb = NSPasteboard(name: NSPasteboard.Name("fb-drag-\(UUID().uuidString)"))
        pb.clearContents(); pb.writeObjects(writers)
        self.point = point; self.window = window
    }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .link, .generic] }
    var draggingLocation: NSPoint { point }
    var draggedImageLocation: NSPoint { point }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pb }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop: ObjCBool = false
        for (i, o) in (pb.readObjects(forClasses: classArray, options: searchOptions) ?? []).enumerated() where !stop.boolValue {
            block(NSDraggingItem(pasteboardWriter: o as! NSPasteboardWriting), i, &stop)
        }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}

    /// The view that takes the drop, found by AppKit's rule for a drag: from the window's frame view, down only into
    /// views whose frame holds the point (front subviews first), the deepest one registered for a type on the
    /// pasteboard. A view SwiftUI leaves at zero size (a glass card's content) hides everything in it, as in a real drag.
    /// Public API, so release builds (the macOS 15 checks run the app bundle) check it too; debug builds also ask
    /// AppKit's own drag hit test and print a FAIL when the two differ.
    func target() -> NSView? {
        guard let root = window.contentView?.superview ?? window.contentView else { return nil }
        let types = Set(pb.types ?? [])
        func find(_ v: NSView, _ p: NSPoint) -> NSView? {
            guard !v.isHidden, v.frame.contains(p) else { return nil }
            let q = v.convert(p, from: v.superview)
            for sub in v.subviews.reversed() { if let t = find(sub, q) { return t } }
            return Set(v.registeredDraggedTypes).isDisjoint(with: types) ? nil : v
        }
        let found = find(root, point)
        #if DEBUG
        typealias HitTest = @convention(c) (NSView, Selector, UnsafePointer<NSPoint>, NSSet) -> NSView?
        let sel = NSSelectorFromString("_hitTest:dragTypes:")
        if let m = class_getInstanceMethod(NSView.self, sel) {
            var p = point
            let appkit = unsafeBitCast(method_getImplementation(m), to: HitTest.self)(root, sel, &p, NSSet(array: types.map(\.rawValue)))
            if appkit !== found {
                print("FakeDrag: AppKit's drag hit test finds \(appkit.map { "\(type(of: $0))" } ?? "none"), FakeDrag \(found.map { "\(type(of: $0))" } ?? "none") FAIL")
            }
        }
        #endif
        return found
    }
    /// Entered on `target()`: the view that took it, nil when none did.
    func enter() -> NSView? {
        guard let t = target() else { return nil }
        guard !t.draggingEntered(self).isEmpty else { t.draggingExited(self); return nil }
        _ = t.draggingUpdated(self)
        return t
    }
    /// Prepare, perform and conclude on the entered view: whether it took the drop.
    func finish(_ t: NSView) -> Bool {
        let ok = t.prepareForDragOperation(self) && t.performDragOperation(self)
        t.concludeDragOperation(self)
        return ok
    }
}
