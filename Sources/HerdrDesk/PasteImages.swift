import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Images pasted into the composer. Files live in ~/Library/Caches/HerdrDesk/paste and are all ours.
enum PasteImages {
    nonisolated(unsafe) static var directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HerdrDesk/paste", isDirectory: true)

    /// PNG files saved from the pasteboard, or nil when it holds no image to take.
    /// Text wins over raw image data (copying rich text must paste text); image files win over their file names.
    static func capture(from pb: NSPasteboard) -> [URL]? {
        var out: [URL] = []
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true,
                                                          .urlReadingContentsConformToTypes: [UTType.image.identifier]]
        if let files = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL], !files.isEmpty {
            for f in files { if let png = pngData(NSImage(contentsOf: f)), let u = write(png) { out.append(u) } }
            return out.isEmpty ? nil : out
        }
        if let s = pb.string(forType: .string), !s.isEmpty { return nil }
        if let d = pb.data(forType: .png), let u = write(d) { return [u] }
        if let d = pb.data(forType: .tiff), let png = pngData(NSImage(data: d)), let u = write(png) { return [u] }
        return nil
    }

    /// Cheap type check (no file written): is there an image Paste should take? Same rule as `capture`.
    static func hasImage(_ pb: NSPasteboard) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true,
                                                          .urlReadingContentsConformToTypes: [UTType.image.identifier]]
        if pb.canReadObject(forClasses: [NSURL.self], options: opts) { return true }
        if let s = pb.string(forType: .string), !s.isEmpty { return false }
        return pb.types?.contains { $0 == .png || $0 == .tiff } ?? false
    }

    private static func pngData(_ image: NSImage?) -> Data? {
        guard let t = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: t) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
    private static func write(_ png: Data) -> URL? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString + ".png")
        do { try png.write(to: url, options: .atomic); return url } catch { return nil }
    }

    /// Deletes a file only if it is one of ours.
    static func remove(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// At launch: drop cache files older than `days`.
    static func purgeOld(days: Int = 7) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files where ["png", "jpg"].contains(f.pathExtension) {
            if let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m < cutoff { remove(f) }
        }
    }
}

struct PasteChip: View {
    let url: URL
    let onRemove: () -> Void
    @State private var image: NSImage?
    init(url: URL, onRemove: @escaping () -> Void) { self.url = url; self.onRemove = onRemove }
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image { Image(nsImage: image).resizable().scaledToFill() } else { Color.primary.opacity(0.08) }
            }
            .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Color.primary.opacity(0.12)))
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.6)).font(.title3)
            }
            .buttonStyle(.plain).offset(x: 5, y: -5).help("Remove")
        }
        .padding(.top, 5).padding(.trailing, 5)
        .task { image = NSImage(contentsOf: url) }
    }
}
