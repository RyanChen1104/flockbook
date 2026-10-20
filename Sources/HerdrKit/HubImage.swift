import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image from a remote device (remote-protocol.md 3.3). The type comes from the magic bytes only; the pixel size
/// is read from the header before any decoding; the first frame is decoded and drawn into a new image, which is
/// written without metadata (no EXIF, GPS, camera, time) to a new random file in the hub's folder. Nothing of the
/// upload's bytes reaches the agent.
public enum HubImage {
    public static let maxBytes = 10 * 1024 * 1024
    public static let maxPartBytes = 640 * 1024
    public static let maxParts = 16
    /// Header limits, checked before decoding (a decompression bomb is refused here).
    public static let maxSide = 12_000, maxPixels = 50_000_000
    /// The output's long side.
    public static let outputSide = 4_096

    public enum Kind: Sendable, Hashable {
        case png, jpeg, heic, webp
        var type: UTType { switch self { case .png: .png; case .jpeg: .jpeg; case .heic: .heic; case .webp: .webP } }
    }

    public enum Failure: Error, Sendable, Hashable {
        /// Not PNG, JPEG, HEIC or WebP by its first bytes.
        case notImage
        /// Over 10 MiB, or the header names too many pixels.
        case tooLarge
        /// The bytes do not decode.
        case undecodable
        case writeFailed
    }

    public struct Output: Sendable, Hashable {
        public var url: URL
        public var width: Int, height: Int
        public var bytes: Int
    }

    /// HEIF brands of still images (ISO/IEC 23008-12); not video brands such as mp42.
    private static let heifBrands: Set<String> = ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1"]

    /// The type by the first bytes, never by a name or MIME type.
    public static func kind(_ d: Data) -> Kind? {
        let b = [UInt8](d.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { return .png }
        if b.starts(with: [0xff, 0xd8, 0xff]) { return .jpeg }
        guard b.count == 12 else { return nil }
        if b[0..<4] == [0x52, 0x49, 0x46, 0x46][...], b[8..<12] == [0x57, 0x45, 0x42, 0x50][...] { return .webp }   // RIFF....WEBP
        if b[4..<8] == [0x66, 0x74, 0x79, 0x70][...], heifBrands.contains(String(decoding: b[8..<12], as: UTF8.self)) { return .heic }  // ftyp<brand>
        return nil
    }

    /// Checks, decodes and writes `data` as a new image into `dir` (made mode 700 if missing). The file: mode 600,
    /// `remote-<random>.png` for a PNG, else `.jpg`, created exclusively (never an existing file or a link).
    public static func reencode(_ data: Data, into dir: URL) throws -> Output {
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        guard let kind = kind(data) else { throw Failure.notImage }
        let png = kind == .png
        let f = try frame(data, type: kind.type, side: outputSide)
        let image = try redraw(f, width: f.width, height: f.height, alpha: png)
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, (png ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil) else { throw Failure.writeFailed }
        CGImageDestinationAddImage(dest, image, (png ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.85]) as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.writeFailed }

        let url = dir.appendingPathComponent("remote-\(UUID().uuidString).\(png ? "png" : "jpg")")
        try write(out as Data, to: url, dir: dir)
        return Output(url: url, width: image.width, height: image.height, bytes: out.length)
    }

    /// The first frame of `data`, an image of `type` by its first bytes: the size checked from the header before any
    /// decoding (a decompression bomb is refused here), orientation applied, the long side at most `side`.
    static func frame(_ data: Data, type: UTType, side: Int) throws -> CGImage {
        // A PNG's size is at fixed bytes (IHDR); ImageIO gives no size at all for a huge one.
        if type == .png, let (w, h) = pngSize(data), w > maxSide || h > maxSide || w * h > maxPixels { throw Failure.tooLarge }
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, noCache),
              let found = CGImageSourceGetType(src).flatMap({ UTType($0 as String) }), found.conforms(to: type) || type.conforms(to: found)
        else { throw Failure.undecodable }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, noCache) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0 else { throw Failure.undecodable }
        guard w <= maxSide, h <= maxSide, w * h <= maxPixels else { throw Failure.tooLarge }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: min(side, max(w, h)), kCGImageSourceShouldCacheImmediately: true]
        guard CGImageSourceGetStatusAtIndex(src, 0) == .statusComplete,
              let frame = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw Failure.undecodable }
        return frame
    }

    /// New pixels in a plain sRGB bitmap, `width`x`height`: nothing of the source file's structure is kept. Without
    /// `alpha`, white behind.
    static func redraw(_ frame: CGImage, width: Int, height: Int, alpha: Bool) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Failure.undecodable }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if !alpha { ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(rect) }
        ctx.interpolationQuality = .high
        ctx.draw(frame, in: rect)
        guard let image = ctx.makeImage() else { throw Failure.undecodable }
        return image
    }

    // MARK: Pictures for remote devices

    /// A picture from a session log (`LogImage.read`) for a remote device (remote-protocol.md 3.4): a JPEG without
    /// metadata. The preview is what the conversation shows; the full picture only when the device asks for it.
    public static let previewSide = 1_024, previewBytes = 256 * 1024
    public struct Encoded: Sendable, Hashable {
        public var data: Data
        public var width: Int, height: Int
    }

    /// The type of a log's picture by its header (PNG, JPEG, WebP, GIF).
    private static func logType(_ data: Data) -> UTType? {
        switch LogImage.header(data)?.format {
        case .png: .png
        case .jpeg: .jpeg
        case .webp: .webP
        case .gif: .gif
        case nil: nil
        }
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Long side at most `previewSide`, at most `previewBytes`: lower quality first, then a smaller picture. Nil: not
    /// a picture this takes, or too large to decode.
    public static func preview(_ data: Data) -> Encoded? {
        guard let type = logType(data), let f = try? frame(data, type: type, side: previewSide) else { return nil }
        var w = f.width, h = f.height
        while true {
            guard let image = try? redraw(f, width: w, height: h, alpha: false) else { return nil }
            for q in [0.8, 0.6, 0.45, 0.3] {
                if let d = jpeg(image, quality: q), d.count <= previewBytes { return Encoded(data: d, width: w, height: h) }
            }
            guard max(w, h) > 64 else { return nil }
            w = max(1, w * 3 / 4); h = max(1, h * 3 / 4)
        }
    }

    /// Long side at most `outputSide`, at most `maxBytes` (`maxParts` parts). Nil: not a picture, or too large.
    public static func full(_ data: Data) -> Encoded? {
        guard let type = logType(data), let f = try? frame(data, type: type, side: outputSide),
              let image = try? redraw(f, width: f.width, height: f.height, alpha: false) else { return nil }
        for q in [0.85, 0.7, 0.5] {
            if let d = jpeg(image, quality: q), d.count <= maxBytes { return Encoded(data: d, width: image.width, height: image.height) }
        }
        return nil
    }

    /// `data` in parts of at most `maxPartBytes`, in order.
    public static func parts(_ data: Data) -> [Data] {
        stride(from: 0, to: data.count, by: maxPartBytes).map { Data(data[data.startIndex + $0 ..< data.startIndex + min($0 + maxPartBytes, data.count)]) }
    }

    /// Width and height from a PNG's IHDR chunk (bytes 16-23), when it is the first chunk.
    static func pngSize(_ d: Data) -> (Int, Int)? {
        let b = [UInt8](d.prefix(24))
        guard b.count == 24, b[12..<16] == [0x49, 0x48, 0x44, 0x52][...] else { return nil }   // IHDR
        func be(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        return (be(16), be(20))
    }

    /// The hub's files in the cache folder at most (oldest go first), and their age.
    public static let cacheMaxFiles = 200, cacheMaxBytes = 512 * 1024 * 1024
    public static let cacheMaxAge: TimeInterval = 7 * 86_400
    /// Deletes the hub's own files (`remote-<UUID>.png|jpg`, regular files) older than `maxAge`, then the oldest
    /// beyond `maxFiles` or `maxBytes`. Never another name. The number deleted.
    @discardableResult
    public static func purge(_ dir: URL, maxFiles: Int = cacheMaxFiles, maxBytes: Int = cacheMaxBytes, maxAge: TimeInterval = cacheMaxAge,
                             now: Date = Date()) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var files: [(path: String, at: Date, bytes: Int)] = []
        for n in names where n.hasPrefix("remote-") && ImagePaste.isOwnName(n) {
            let path = dir.appendingPathComponent(n).path
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }
            files.append((path, Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)), Int(st.st_size)))
        }
        files.sort { $0.at < $1.at }
        var total = files.reduce(0) { $0 + $1.bytes }, count = files.count, gone = 0
        for f in files {
            guard now.timeIntervalSince(f.at) > maxAge || count > maxFiles || total > maxBytes else { break }
            if unlink(f.path) == 0 { gone += 1 }
            count -= 1; total -= f.bytes
        }
        return gone
    }

    /// Opens `dir` as our own folder: made mode 700 if missing; a real directory (no link), owned by us, closed to
    /// others. The file is then created inside the open folder, so a folder swapped meanwhile is not followed.
    private static func write(_ data: Data, to url: URL, dir: URL) throws {
        if mkdir(dir.path, 0o700) != 0, errno != EEXIST {
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { throw Failure.writeFailed }
        }
        let dfd = open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dfd >= 0 else { throw Failure.writeFailed }
        defer { close(dfd) }
        var st = stat()
        guard fstat(dfd, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else { throw Failure.writeFailed }
        if st.st_mode & 0o077 != 0 { guard fchmod(dfd, 0o700) == 0 else { throw Failure.writeFailed } }
        let name = url.lastPathComponent
        let fd = openat(dfd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.writeFailed }
        let ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        close(fd)
        if !ok { unlinkat(dfd, name, 0); throw Failure.writeFailed }
    }
}

/// At most `max` jobs at once, the rest wait in order (image decoding on the hub: 2).
@MainActor public final class HubWorkSlots {
    public static let images = HubWorkSlots(max: 2)
    private let max: Int
    private var running = 0
    private var queue: [CheckedContinuation<Void, Never>] = []
    /// Jobs waiting for a slot; jobs that ran.
    public var waiting: Int { queue.count }
    public private(set) var started = 0
    public init(max: Int) { self.max = Swift.max(1, max) }

    public func run<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        if running < max { running += 1 } else { await withCheckedContinuation { queue.append($0) } }   // the slot is handed over
        started += 1
        let result = await Task.detached(priority: .userInitiated) { await work() }.value
        if queue.isEmpty { running -= 1 } else { queue.removeFirst().resume() }
        return result
    }
}

/// Uploads per device over all its connections: at most `maxImages` images and `maxBytes` in `window`. One per hub.
@MainActor public final class HubUploadLimiter {
    public static let maxImages = 20
    public static let maxBytes = 100 * 1024 * 1024
    public static let window: TimeInterval = 600

    private let now: () -> Date
    private var log: [String: [(at: Date, bytes: Int, image: Bool)]] = [:]

    public init(now: @escaping () -> Date = Date.init) { self.now = now }

    /// Unsent images held per device over its connections; connections per device.
    public static let maxHeld = 8, maxConnections = 4
    private var heldCount: [String: Int] = [:]
    private var connections: [String: Int] = [:]

    /// Takes one held slot for `device`; false when it holds `maxHeld` already.
    public func hold(device: String) -> Bool {
        guard held(device: device) < Self.maxHeld else { return false }
        heldCount[device, default: 0] += 1
        return true
    }
    public func release(device: String, count: Int = 1) { heldCount[device] = Swift.max(0, held(device: device) - count) }
    public func held(device: String) -> Int { heldCount[device] ?? 0 }
    /// Takes one connection slot for `device`; false when it has `maxConnections` open.
    public func connect(device: String) -> Bool {
        guard connections[device, default: 0] < Self.maxConnections else { return false }
        connections[device, default: 0] += 1
        return true
    }
    public func disconnect(device: String) { connections[device] = Swift.max(0, (connections[device] ?? 0) - 1) }
    /// What `device` used in the window.
    public func used(device: String) -> (images: Int, bytes: Int) {
        let t = now()
        let e = (log[device] ?? []).filter { t.timeIntervalSince($0.at) < Self.window }
        return (e.filter(\.image).count, e.reduce(0) { $0 + $1.bytes })
    }
    /// Counts written bytes too (the stored file), over the limit or not: the next upload sees them.
    public func count(device: String, bytes: Int) { log[device, default: []].append((now(), bytes, false)) }

    /// Counts `bytes` (and one image when `image`) for `device`. False, and nothing counted, when over a limit.
    public func take(device: String, bytes: Int, image: Bool) -> Bool {
        let t = now()
        var entries = (log[device] ?? []).filter { t.timeIntervalSince($0.at) < Self.window }
        let images = entries.filter(\.image).count + (image ? 1 : 0)
        let total = entries.reduce(0) { $0 + $1.bytes } + bytes
        guard images <= Self.maxImages, total <= Self.maxBytes else { log[device] = entries; return false }
        entries.append((t, bytes, image))
        log[device] = entries
        return true
    }
}
