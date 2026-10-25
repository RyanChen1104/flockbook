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

    /// The view that takes the drop, found as AppKit finds it: its own drag hit test from the window's frame view
    /// (`-[NSView _hitTest:dragTypes:]`, private, checks only). It goes down only through views whose frame holds the
    /// point, so a view SwiftUI leaves at zero size (the glass card's content) hides everything in it, as in a real drag.
    func target() -> NSView? {
        typealias HitTest = @convention(c) (NSView, Selector, UnsafePointer<NSPoint>, NSSet) -> NSView?
        let sel = NSSelectorFromString("_hitTest:dragTypes:")
        guard let root = window.contentView?.superview ?? window.contentView,
              let m = class_getInstanceMethod(NSView.self, sel) else { print("FakeDrag: no AppKit drag hit test"); return nil }
        var p = point
        return unsafeBitCast(method_getImplementation(m), to: HitTest.self)(root, sel, &p, NSSet(array: (pb.types ?? []).map(\.rawValue)))
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
