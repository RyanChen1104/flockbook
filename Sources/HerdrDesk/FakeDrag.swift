import AppKit

/// A drag for the checks: AppKit's route without a mouse. The window's deepest view under `point` that registered
/// for one of the pasteboard's types gets entered, prepare and perform, as a real drop does.
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

    /// The view that takes the drop: the frontmost view under the point registered for a type on the pasteboard
    /// (`public.item`, SwiftUI's drop view, takes any). SwiftUI puts its drop view beside the content, not above it
    /// in the hit-test chain, so every view is looked at, later siblings and subviews in front.
    func target() -> NSView? {
        let types = Set(pb.types ?? [])
        func takes(_ view: NSView) -> Bool {
            let r = Set(view.registeredDraggedTypes)
            return !r.isDisjoint(with: types) || r.contains(NSPasteboard.PasteboardType("public.item"))
        }
        var front: NSView?
        func walk(_ v: NSView) {
            guard !v.isHidden else { return }
            if takes(v), v.convert(v.bounds, to: nil).contains(point) { front = v }
            v.subviews.forEach(walk)
        }
        if let root = window.contentView?.superview ?? window.contentView { walk(root) }
        return front
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
