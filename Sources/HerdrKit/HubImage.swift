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
        // A PNG's size is at fixed bytes (IHDR); ImageIO gives no size at all for a huge one.
        if kind == .png, let (w, h) = pngSize(data), w > maxSide || h > maxSide || w * h > maxPixels { throw Failure.tooLarge }
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, noCache),
              let found = CGImageSourceGetType(src).flatMap({ UTType($0 as String) }), found.conforms(to: kind.type) || kind.type.conforms(to: found)
        else { throw Failure.undecodable }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, noCache) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0 else { throw Failure.undecodable }
        guard w <= maxSide, h <= maxSide, w * h <= maxPixels else { throw Failure.tooLarge }

        // The first frame, orientation applied, the long side capped.
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: min(outputSide, max(w, h)), kCGImageSourceShouldCacheImmediately: true]
        guard CGImageSourceGetStatusAtIndex(src, 0) == .statusComplete,
              let frame = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw Failure.undecodable }

        // New pixels in a plain sRGB bitmap: nothing of the source file's structure is kept.
        let png = kind == .png
        let ow = frame.width, oh = frame.height
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: png ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Failure.undecodable }
        let rect = CGRect(x: 0, y: 0, width: ow, height: oh)
        if !png { ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(rect) }
        ctx.draw(frame, in: rect)
        guard let image = ctx.makeImage() else { throw Failure.undecodable }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, (png ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil) else { throw Failure.writeFailed }
        CGImageDestinationAddImage(dest, image, (png ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.85]) as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.writeFailed }

        let url = dir.appendingPathComponent("remote-\(UUID().uuidString).\(png ? "png" : "jpg")")
        try write(out as Data, to: url, dir: dir)
        return Output(url: url, width: ow, height: oh, bytes: out.length)
    }

    /// Width and height from a PNG's IHDR chunk (bytes 16-23), when it is the first chunk.
    static func pngSize(_ d: Data) -> (Int, Int)? {
        let b = [UInt8](d.prefix(24))
        guard b.count == 24, b[12..<16] == [0x49, 0x48, 0x44, 0x52][...] else { return nil }   // IHDR
        func be(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        return (be(16), be(20))
    }

    private static func write(_ data: Data, to url: URL, dir: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { throw Failure.writeFailed }
        } else {
            // Our folder only: a real directory (not a link to elsewhere), closed to other users.
            let attrs = try? fm.attributesOfItem(atPath: dir.path)
            guard attrs?[.type] as? FileAttributeType == .typeDirectory else { throw Failure.writeFailed }
            if (attrs?[.posixPermissions] as? Int ?? 0) & 0o077 != 0 { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
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
        if !ok { unlink(url.path); throw Failure.writeFailed }
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
