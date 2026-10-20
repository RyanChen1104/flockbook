import AppKit
import HerdrKit
import ImageIO
import QuickLook
import SwiftUI

// Pictures from the session log. A row knows each picture's size from its ref, so it takes its full height before the
// picture loads (the scroll anchor never moves for a decode). Thumbnails are decoded off the main thread into a bounded
// cache; a click opens a private copy in Quick Look.

private struct LogURLKey: EnvironmentKey { static let defaultValue: URL? = nil }
extension EnvironmentValues {
    /// The log file the conversation's picture refs point into (`HerdrStore.logURL`). Nil: pictures stay placeholders.
    var logURL: URL? { get { self[LogURLKey.self] } set { self[LogURLKey.self] = newValue } }
}

/// Picture sizes in points, from the ref alone. Never larger than the picture's pixels; whole points.
enum PictureLayout {
    /// A thumbnail in a strip: at most `maxHeight` high and `maxWidth` wide.
    static func thumb(_ r: LogImage.Ref, maxHeight: CGFloat = 120, maxWidth: CGFloat = 480) -> CGSize {
        scaled(r, maxWidth: maxWidth, maxHeight: maxHeight)
    }
    /// A tool's lone picture: at most 480 pt (or `maxWidth`) wide and 640 pt high.
    static func fit(_ r: LogImage.Ref, maxWidth: CGFloat) -> CGSize {
        scaled(r, maxWidth: Swift.min(480, maxWidth), maxHeight: 640)
    }
    private static func scaled(_ r: LogImage.Ref, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard r.width > 0, r.height > 0 else { return .zero }
        let w = CGFloat(r.width), h = CGFloat(r.height)
        let k: CGFloat = Swift.min(1, maxWidth / w, maxHeight / h)
        let sw: CGFloat = (w * k).rounded(), sh: CGFloat = (h * k).rounded()
        return CGSize(width: Swift.max(1, sw), height: Swift.max(1, sh))
    }
}

/// Decoded thumbnails, keyed by log, line, index, the ref's format and size, and pixel size. NSCache is thread safe and drops entries under memory
/// pressure; the limits keep a long conversation of screenshots small.
final class PictureCache: @unchecked Sendable {
    static let shared = PictureCache()
    private let cache = NSCache<NSString, NSImage>()
    init() { cache.countLimit = 120; cache.totalCostLimit = 64 << 20 }
    var countLimit: Int { cache.countLimit }
    var totalCostLimit: Int { cache.totalCostLimit }
    func removeAll() { cache.removeAllObjects() }

    /// The ref's format and size are part of the key, so a stale ref misses and goes back to the log's header check.
    private func key(_ url: URL, _ r: LogImage.Ref, _ px: Int) -> NSString {
        "\(url.path)|\(r.offset ?? 0)|\(r.index)|\(r.format)|\(r.width)x\(r.height)|\(px)" as NSString
    }

    func cached(url: URL, ref: LogImage.Ref, maxPixel: Int) -> NSImage? { cache.object(forKey: key(url, ref, maxPixel)) }

    /// Reads the picture from the log and decodes it to at most `maxPixel` on its long side. Nil when the log no longer
    /// has that picture (`LogImage.read` checks the line and the header) or it does not decode.
    func load(url: URL, ref: LogImage.Ref, maxPixel: Int) async -> NSImage? {
        if let hit = cached(url: url, ref: ref, maxPixel: maxPixel) { return hit }
        let cg = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let data = LogImage.read(ref, from: url), let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 1)]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }.value
        guard let cg else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: key(url, ref, maxPixel), cost: cg.bytesPerRow * cg.height)
        return img
    }
}

/// The copies Quick Look shows: one at a time, mode 600 in a folder of mode 700. Writing a new one removes the others
/// (also any left by a quit while a preview was open).
enum PictureFiles {
    static let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("flockbook-pictures", isDirectory: true)

    static func write(_ data: Data, format: LogImage.Format, in dir: URL = dir) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch { return nil }
        for old in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: old) }
        let ext = format == .jpeg ? "jpg" : format.rawValue
        let file = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        return fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) ? file : nil
    }

    static func remove(_ url: URL, in dir: URL = dir) {
        guard url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// At most `limit` picture reads at a time (each reads and parses its whole log line).
actor PictureGate {
    static let shared = PictureGate(limit: 2)
    let limit: Int
    init(limit: Int) { self.limit = limit }
    func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T { await work() }
}

/// The Quick Look copy of one picture.
@MainActor @Observable final class PreviewOpener {
    let dir: URL
    var preview: URL? { didSet { if let oldValue, oldValue != preview { PictureFiles.remove(oldValue, in: dir) } } }
    init(dir: URL = PictureFiles.dir) { self.dir = dir }

    func open(_ ref: LogImage.Ref, from url: URL) {
        let dir = dir
        Task {
            let data = await Task.detached(priority: .userInitiated) { LogImage.read(ref, from: url) }.value
            if let data, let file = PictureFiles.write(data, format: ref.format, in: dir) { preview = file }
        }
    }

    func close() { preview = nil }
}

/// One picture at a fixed size: a placeholder until the thumbnail loads. Click: Quick Look.
struct LogPicture: View {
    let ref: LogImage.Ref
    let size: CGSize
    @Environment(\.logURL) private var url
    @Environment(\.displayScale) private var scale
    @State private var image: NSImage?
    @State private var preview: URL?
    @State private var hover = false

    /// Pixels on the long side for a picture drawn at `size` points.
    static func maxPixel(_ size: CGSize, scale: CGFloat) -> Int {
        let side: CGFloat = Swift.max(size.width, size.height) * Swift.max(scale, 1)
        return Int(side.rounded(.up))
    }
    private var maxPixel: Int { Self.maxPixel(size, scale: scale) }

    static func taskID(url: URL?, ref: LogImage.Ref, maxPixel: Int) -> String { "\(url?.path ?? "")|\(ref.offset ?? 0)|\(ref.index)|\(maxPixel)" }
    private var task: String { Self.taskID(url: url, ref: ref, maxPixel: maxPixel) }

    var body: some View {
        picture
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { open() }
            .help("Open in Quick Look")
            .accessibilityElement()
            .accessibilityLabel("Picture, \(ref.width) by \(ref.height) pixels")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
            .task(id: task) { await load() }
            .quickLookPreview($preview)
            .onChange(of: preview) { old, new in if let old, old != new { PictureFiles.remove(old) } }
            .onDisappear { if let preview { PictureFiles.remove(preview) } }
    }

    private var picture: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        return ZStack {
            Color.primary.opacity(0.06)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else if size.height >= 24 {
                Image(systemName: "photo").font(.title3).foregroundStyle(.tertiary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(hover ? 0.25 : 0.1), lineWidth: 0.5))
    }

    private func load() async {
        guard let url else { image = nil; return }
        image = PictureCache.shared.cached(url: url, ref: ref, maxPixel: maxPixel)
        if image == nil { image = await PictureCache.shared.load(url: url, ref: ref, maxPixel: maxPixel) }
    }

    private func open() {
        guard let url else { return }
        let ref = ref
        Task {
            let data = await Task.detached(priority: .userInitiated) { LogImage.read(ref, from: url) }.value
            if let data, let file = PictureFiles.write(data, format: ref.format) { preview = file }
        }
    }
}

/// The pictures of one message or tool group. A tool's lone picture fits `single` (its width cap); several, or the
/// owner's pictures, are a strip of thumbnails.
struct PictureStrip: View {
    /// The most pictures one strip draws; the rest are counted on a "+N" tile.
    static let maxShown = 8
    static func split(_ refs: [LogImage.Ref]) -> (shown: [LogImage.Ref], more: Int) {
        (refs.filter { $0.width > 0 && $0.height > 0 }, 0)
    }
    let refs: [LogImage.Ref]
    var single: CGFloat? = nil
    var maxWidth: CGFloat = 480

    var body: some View {
        let shown = refs.filter { $0.width > 0 && $0.height > 0 }
        if shown.count == 1, let single {
            LogPicture(ref: shown[0], size: PictureLayout.fit(shown[0], maxWidth: single))
        } else if !shown.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, r in LogPicture(ref: r, size: PictureLayout.thumb(r, maxWidth: maxWidth)) }
            }
        }
    }
}
