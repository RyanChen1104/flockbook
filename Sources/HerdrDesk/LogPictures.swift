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

/// Decoded thumbnails, keyed by log and the whole ref (place, format, size, fingerprint) and pixel size. NSCache is
/// thread safe and drops entries under memory pressure; the limits keep a long conversation of screenshots small.
final class PictureCache: @unchecked Sendable {
    static let shared = PictureCache()
    private let cache = NSCache<NSString, NSImage>()
    init() { cache.countLimit = 120; cache.totalCostLimit = 64 << 20 }
    var countLimit: Int { cache.countLimit }
    var totalCostLimit: Int { cache.totalCostLimit }
    func removeAll() { cache.removeAllObjects() }

    private func key(_ url: URL, _ r: LogImage.Ref, _ px: Int) -> NSString { LogPicture.taskID(url: url, ref: r, maxPixel: px) as NSString }

    func cached(url: URL, ref: LogImage.Ref, maxPixel: Int) -> NSImage? { cache.object(forKey: key(url, ref, maxPixel)) }

    /// Reads the picture from the log and decodes it to at most `maxPixel` on its long side, through `PictureGate`. Nil
    /// when the log no longer has that picture (`LogImage.read` checks the line, fingerprint and header), it does not
    /// decode, or the caller was cancelled while it waited.
    func load(url: URL, ref: LogImage.Ref, maxPixel: Int) async -> NSImage? {
        if let hit = cached(url: url, ref: ref, maxPixel: maxPixel) { return hit }
        let cg = await PictureGate.shared.run { () -> CGImage? in
            guard !Task.isCancelled else { return nil }
            return await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let data = LogImage.read(ref, from: url), let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                             kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 1)]
                return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            }.value
        }
        guard let cg else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: key(url, ref, maxPixel), cost: cg.bytesPerRow * cg.height)
        return img
    }
}

/// At most `limit` picture reads at a time (each reads and parses its whole log line). The others wait in order.
actor PictureGate {
    static let shared = PictureGate(limit: 2)
    let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = Swift.max(1, limit) }

    func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        if running < limit { running += 1 } else { await withCheckedContinuation { waiting.append($0) } }
        // A finished read hands its place to the next waiter, or frees it.
        defer { if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() } }
        return await work()
    }
}

/// The copies Quick Look shows: one at a time, mode 600 in a private folder of mode 700. Writing a new one removes the
/// others (also any left by a quit while a preview was open). The folder is used through a descriptor opened without
/// following links, so a symlink in its place (or a file, or a folder of another user) is refused.
enum PictureFiles {
    static let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("flockbook-pictures", isDirectory: true)

    static func write(_ data: Data, format: LogImage.Format, in dir: URL = dir) -> URL? {
        guard let fd = folder(dir, create: true) else { return nil }
        defer { Darwin.close(fd) }
        for name in names(in: fd) { unlinkat(fd, name, 0) }
        let name = "\(UUID().uuidString).\(format == .jpeg ? "jpg" : format.rawValue)"
        let f = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard f >= 0 else { return nil }
        let ok = fchmod(f, 0o600) == 0 && data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            var done = 0
            while done < buf.count {
                let n = Darwin.write(f, buf.baseAddress! + done, buf.count - done)
                if n <= 0 { return false }
                done += n
            }
            return true
        }
        Darwin.close(f)
        guard ok else { unlinkat(fd, name, 0); return nil }
        return dir.appendingPathComponent(name)
    }

    static func remove(_ url: URL, in dir: URL = dir) {
        guard url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL, let fd = folder(dir, create: false) else { return }
        defer { Darwin.close(fd) }
        unlinkat(fd, url.lastPathComponent, 0)
    }

    /// The folder as a descriptor: made with mode 700 when missing (`create`); nil when it is a symlink, not a folder, or
    /// not the user's. Its mode is set back to 700.
    private static func folder(_ dir: URL, create: Bool) -> Int32? {
        if create, mkdir(dir.path, 0o700) != 0, errno != EEXIST { return nil }
        let fd = Darwin.open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(), fchmod(fd, 0o700) == 0 else {
            Darwin.close(fd); return nil
        }
        return fd
    }

    private static func names(in fd: Int32) -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { return [] }
        guard let d = fdopendir(copy) else { Darwin.close(copy); return [] }
        defer { closedir(d) }
        var out: [String] = []
        while let e = readdir(d) {
            let len = Int(e.pointee.d_namlen)
            let name = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix(len), as: UTF8.self) }
            if name != "." && name != ".." { out.append(name) }
        }
        return out
    }
}

/// The Quick Look copy of one picture. A read that finishes after `close()` (the picture went away) writes nothing.
@MainActor @Observable final class PreviewOpener {
    let dir: URL
    var preview: URL? { didSet { if let oldValue, oldValue != preview { PictureFiles.remove(oldValue, in: dir) } } }
    @ObservationIgnored private var work: Task<Void, Never>?
    init(dir: URL = PictureFiles.dir) { self.dir = dir }

    func open(_ ref: LogImage.Ref, from url: URL) {
        work?.cancel()
        let dir = dir
        work = Task {
            let data = await Task.detached(priority: .userInitiated) { LogImage.read(ref, from: url) }.value
            // The check and the write run on the main actor together, so a close() cannot fall between them.
            guard !Task.isCancelled, let data, let file = PictureFiles.write(data, format: ref.format, in: dir) else { return }
            preview = file
        }
    }

    func close() { work?.cancel(); work = nil; preview = nil }
}

/// One picture at a fixed size: a placeholder until the thumbnail loads. Click: Quick Look. Out of view it lets its
/// thumbnail go (the cache may still keep it).
struct LogPicture: View {
    let ref: LogImage.Ref
    let size: CGSize
    @Environment(\.logURL) private var url
    @Environment(\.displayScale) private var scale
    @State private var thumb = Thumbnail()
    @State private var opener = PreviewOpener()
    @State private var hover = false
    @State private var near = false

    /// Pixels on the long side for a picture drawn at `size` points.
    static func maxPixel(_ size: CGSize, scale: CGFloat) -> Int {
        let side: CGFloat = Swift.max(size.width, size.height) * Swift.max(scale, 1)
        return Int(side.rounded(.up))
    }
    private var maxPixel: Int { Self.maxPixel(size, scale: scale) }

    /// The load's identity: the log, the whole ref and the pixel size. Any change starts a new load.
    nonisolated static func taskID(url: URL?, ref: LogImage.Ref, maxPixel: Int) -> String {
        "\(url?.path ?? "")|\(ref.offset ?? 0)|\(ref.index)|\(ref.format.rawValue)|\(ref.width)x\(ref.height)|\(String(ref.digest, radix: 16))|\(maxPixel)"
    }
    private var task: String { Self.taskID(url: url, ref: ref, maxPixel: maxPixel) }

    /// Within a screen of the scroll view's visible part (or in no scroll view). The conversation list is a plain stack
    /// whose rows never disappear, so this, not `onDisappear`, says when a picture loads and when its thumbnail goes.
    nonisolated static func near(_ proxy: GeometryProxy) -> Bool {
        guard let seen = proxy.bounds(of: .scrollView) else { return true }
        let me = CGRect(origin: .zero, size: proxy.size)
        return me.maxY >= seen.minY - seen.height && me.minY <= seen.maxY + seen.height
    }

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
            .onGeometryChange(for: Bool.self, of: Self.near) { near = $0 }
            .task(id: near ? task : nil) { await load() }
            .quickLookPreview(Binding(get: { opener.preview }, set: { opener.preview = $0 }))
            .onDisappear { thumb.clear(); opener.close() }
    }

    private var picture: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        return ZStack {
            Color.primary.opacity(0.06)
            if thumb.shows(task) {
                ThumbnailLayer(thumb: thumb)
            } else if size.height >= 24 {
                Image(systemName: "photo").font(.title3).foregroundStyle(.tertiary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(hover ? 0.25 : 0.1), lineWidth: 0.5))
    }

    private func load() async {
        let id = task
        guard near, let url else { thumb.clear(); return }
        if let hit = PictureCache.shared.cached(url: url, ref: ref, maxPixel: maxPixel) { thumb.set(hit, for: id); return }
        let img = await PictureCache.shared.load(url: url, ref: ref, maxPixel: maxPixel)
        guard !Task.isCancelled, let img else { return }
        thumb.set(img, for: id)
    }

    private func open() {
        if let url { opener.open(ref, from: url) }
    }
}

/// A picture's decoded thumbnail and the load it came from; it is drawn only while that is still the view's load. The
/// view graph holds this box, not the image: a lazy row out of view keeps its last body, so `clear()` also empties the
/// layer that draws it, and the thumbnail goes without a new render.
@MainActor @Observable final class Thumbnail {
    private(set) var id: String?
    @ObservationIgnored private(set) var image: NSImage?
    @ObservationIgnored weak var layerView: ThumbnailLayer.LayerView?
    /// Every thumbnail drawn and still alive anywhere (weak): the checks see that one scrolled away is gone.
    static let shown = NSHashTable<NSImage>.weakObjects()

    func shows(_ task: String) -> Bool { id == task }
    func set(_ image: NSImage, for task: String) { self.image = image; id = task; layerView?.show(image); Self.shown.add(image) }
    func clear() { image = nil; id = nil; layerView?.show(nil) }
}

/// Draws a `Thumbnail` filled and clipped to its frame, in a layer `Thumbnail.clear()` can empty directly.
struct ThumbnailLayer: NSViewRepresentable {
    let thumb: Thumbnail

    final class LayerView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.contentsGravity = .resizeAspectFill
            layer?.minificationFilter = .trilinear
            layer?.masksToBounds = true
        }
        required init?(coder: NSCoder) { nil }
        func show(_ image: NSImage?) { layer?.contents = image }
    }

    func makeNSView(context: Context) -> LayerView { LayerView() }
    func updateNSView(_ view: LayerView, context: Context) {
        thumb.layerView = view
        view.show(thumb.image)
    }
}

/// The pictures of one message or tool group. A tool's lone picture fits `single` (its width cap); several, or the
/// owner's pictures, are a strip of thumbnails: at most `maxShown`, the rest counted on a "+N" tile.
struct PictureStrip: View {
    static let maxShown = 8
    static func split(_ refs: [LogImage.Ref]) -> (shown: [LogImage.Ref], more: Int) {
        let drawn = refs.filter { $0.width > 0 && $0.height > 0 }
        return (Array(drawn.prefix(maxShown)), Swift.max(0, drawn.count - maxShown))
    }
    let refs: [LogImage.Ref]
    var single: CGFloat? = nil
    var maxWidth: CGFloat = 480

    var body: some View {
        let (shown, more) = Self.split(refs)
        if shown.count == 1, more == 0, let single {
            LogPicture(ref: shown[0], size: PictureLayout.fit(shown[0], maxWidth: single))
        } else if !shown.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, r in LogPicture(ref: r, size: PictureLayout.thumb(r, maxWidth: maxWidth)) }
                if more > 0 { MoreTile(count: more, height: tileHeight(shown)) }
            }
        }
    }

    private func tileHeight(_ shown: [LogImage.Ref]) -> CGFloat {
        let heights: [CGFloat] = shown.map { PictureLayout.thumb($0, maxWidth: maxWidth).height }
        return Swift.max(24, heights.max() ?? 24)
    }
}

/// "+N": the pictures a strip does not draw.
private struct MoreTile: View {
    let count: Int
    let height: CGFloat
    var body: some View {
        Text("+\(count)")
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 56, height: height)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("\(count) more pictures")
    }
}
