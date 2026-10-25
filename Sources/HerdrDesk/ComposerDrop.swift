import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files dropped on the composer: file URLs as they are, image file promises (a screenshot's thumbnail) received into
/// a temporary folder first. Anything else (text) is not taken.
@MainActor final class FileDrop {
    var onFiles: (([URL]) -> Void)?
    /// A file drag is over the composer (it shows its drop outline).
    var onTarget: ((Bool) -> Void)?
    static let types: [NSPasteboard.PasteboardType] = [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }
    /// Receives one promised file into a folder (the checks replace it: a promise needs a real drag session).
    static var receive: (NSFilePromiseReceiver, URL, @escaping (URL?) -> Void) -> Void = { p, dir, done in
        p.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { url, error in done(error == nil ? url : nil) }
    }
    private static let fileOpts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    private func files(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: Self.fileOpts) as? [URL] ?? []
    }
    private func imagePromises(_ info: NSDraggingInfo) -> [NSFilePromiseReceiver] {
        let all = info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        return all.filter { r in r.fileTypes.contains { UTType($0)?.conforms(to: .image) == true } }
    }
    func takes(_ info: NSDraggingInfo) -> Bool { onFiles != nil && (!files(info).isEmpty || !imagePromises(info).isEmpty) }
    /// Entered or updated: `.copy` with the outline when taken, nil when not.
    func over(_ info: NSDraggingInfo) -> NSDragOperation? {
        guard takes(info) else { return nil }
        onTarget?(true)
        return .copy
    }
    func left() { onTarget?(false) }
    /// The drop: true when taken, nil when not ours.
    func perform(_ info: NSDraggingInfo) -> Bool? {
        guard let onFiles, takes(info) else { return nil }
        onTarget?(false)
        let urls = files(info)
        if !urls.isEmpty { onFiles(urls); return true }
        // Promised files land in a temporary folder; the composer copies the images into its own folder.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fb-drop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let group = DispatchGroup()
        var got: [URL] = []
        let lock = NSLock()
        for p in imagePromises(info) {
            group.enter()
            Self.receive(p, dir) { url in
                if let url { lock.lock(); got.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            onFiles(got)
            try? FileManager.default.removeItem(at: dir)
        }
        return true
    }
}

/// The composer card's drop area, behind its content. A real drag reaches a view only through AppKit's drag hit test,
/// which goes down only into views whose frame holds the point; SwiftUI holds a glass card's content in a zero-size
/// view, so no view inside the card (the text, a drop destination) ever gets a drag. This view sits outside the glass.
struct FileDropArea: NSViewRepresentable {
    var onFiles: (([URL]) -> Void)?
    var onTarget: (Bool) -> Void

    final class DropView: NSView {
        let drop = FileDrop()
        override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes(FileDrop.types) }
        required init?(coder: NSCoder) { fatalError() }
        /// Clicks go to the card's content.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation { drop.over(info) ?? [] }
        override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation { drop.over(info) ?? [] }
        override func draggingExited(_ info: NSDraggingInfo?) { drop.left() }
        override func concludeDragOperation(_ info: NSDraggingInfo?) { drop.left() }
        override func performDragOperation(_ info: NSDraggingInfo) -> Bool { drop.perform(info) ?? false }
    }

    func makeNSView(context: Context) -> DropView { DropView() }
    func updateNSView(_ v: DropView, context: Context) { v.drop.onFiles = onFiles; v.drop.onTarget = onTarget }
}
