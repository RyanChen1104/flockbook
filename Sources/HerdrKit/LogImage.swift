import CryptoKit
import Foundation

/// Pictures stored in session logs (base64 in the JSON). Items keep only a `Ref`; the bytes are read back from the log on demand.
/// Where they are: Claude Code `image` blocks (the owner's paste) and `image` blocks in `tool_result` content; Codex
/// `input_image` data URLs in a message or a tool's output; pi `image` blocks (`data` + `mimeType`) in a `toolResult`.
/// A picture given as a web URL is never fetched.
public enum LogImage {
    public enum Format: String, Sendable, Hashable { case png, jpeg, webp, gif }

    /// Where a picture is: the nth picture (`index`, log order) of the line at byte `offset`. Size from the file header;
    /// `digest` is the `fingerprint` of its base64, so a rewritten log with another picture of the same size reads nothing.
    public struct Ref: Sendable, Hashable {
        public var format: Format
        public var width: Int, height: Int
        public var offset: UInt64?
        public var index: Int
        public var digest: UInt64
        public init(format: Format, width: Int, height: Int, offset: UInt64?, index: Int, digest: UInt64) {
            self.format = format; self.width = width; self.height = height; self.offset = offset; self.index = index; self.digest = digest
        }
    }

    /// A picture's identity: the first 8 bytes of the SHA-256 of its base64 text.
    public static func fingerprint(base64: String) -> UInt64 {
        var text = base64
        let digest = text.withUTF8 { SHA256.hash(data: UnsafeRawBufferPointer($0)) }
        return digest.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// Longest line `read` takes (a tool output of several screenshots).
    static let maxLine = 64 * 1024 * 1024

    // MARK: size from the header

    public static func header(_ d: Data) -> (format: Format, width: Int, height: Int)? {
        let b = [UInt8](d)
        func ok(_ f: Format, _ w: Int, _ h: Int) -> (format: Format, width: Int, height: Int)? { w > 0 && h > 0 ? (f, w, h) : nil }
        func be16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        func le16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func le24(_ i: Int) -> Int { le16(i) | Int(b[i + 2]) << 16 }
        if b.count >= 24, b[0..<8] == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a][...], b[12..<16] == [0x49, 0x48, 0x44, 0x52][...] {
            return ok(.png, be16(16) << 16 | be16(18), be16(20) << 16 | be16(22))
        }
        if b.count >= 10, b[0..<6] == Array("GIF87a".utf8)[...] || b[0..<6] == Array("GIF89a".utf8)[...] {
            return ok(.gif, le16(6), le16(8))
        }
        if b.count >= 16, b[0..<4] == Array("RIFF".utf8)[...], b[8..<12] == Array("WEBP".utf8)[...] {
            switch String(decoding: b[12..<16], as: UTF8.self) {
            case "VP8X":
                guard b.count >= 30 else { return nil }
                return ok(.webp, le24(24) + 1, le24(27) + 1)
            case "VP8L":
                guard b.count >= 25, b[20] == 0x2f else { return nil }
                let bits = le16(21) | le16(23) << 16
                return ok(.webp, bits & 0x3fff + 1, bits >> 14 & 0x3fff + 1)
            case "VP8 ":
                guard b.count >= 30, b[23..<26] == [0x9d, 0x01, 0x2a][...] else { return nil }
                return ok(.webp, le16(26) & 0x3fff, le16(28) & 0x3fff)
            default: return nil
            }
        }
        guard b.count >= 4, b[0] == 0xff, b[1] == 0xd8 else { return nil }
        // JPEG: walk the segments to the frame header (SOF0-15 but DHT, JPG, DAC).
        var i = 2
        while i + 8 < b.count {
            guard b[i] == 0xff else { return nil }
            let m = b[i + 1]
            if m == 0xff { i += 1; continue }
            if m == 0xd8 || m == 0x01 || (0xd0...0xd7).contains(m) { i += 2; continue }
            if m == 0xda || m == 0xd9 { return nil }   // scan data or the end before any frame
            if (0xc0...0xcf).contains(m), ![0xc4, 0xc8, 0xcc].contains(m) { return ok(.jpeg, be16(i + 7), be16(i + 5)) }
            i += 2 + be16(i + 2)
        }
        return nil
    }

    /// Size from the start of base64 text: 48 bytes, or up to 64 KB for a JPEG whose frame sits after EXIF.
    public static func header(base64: String) -> (format: Format, width: Int, height: Int)? {
        for chars in [64, 87_384] {
            let head = base64.utf8.prefix(chars)
            guard let d = Data(base64Encoded: Data(head.prefix(head.count / 4 * 4)), options: .ignoreUnknownCharacters) else { return nil }
            if let h = header(d) { return h }
            guard head.count == chars, d.count >= 2, d[0] == 0xff, d[1] == 0xd8 else { return nil }
        }
        return nil
    }

    // MARK: finding them in a line

    /// A picture in a line: its base64, and the tool call it answers (nil: the message's own).
    struct Found { var base64: String; var call: String? }

    /// Pictures in a parsed line, in log order. The order is what `Ref.index` counts.
    static func found(in o: [String: Any]) -> [Found] {
        if let p = o["payload"] as? [String: Any] { return found(codex: p) }
        if let m = o["message"] as? [String: Any] { return found(message: m) }
        return []
    }

    static func found(codex p: [String: Any]) -> [Found] {
        let type = p["type"] as? String ?? ""
        if type == "message" { return found(blocks: p["content"], call: nil) }
        if type.hasSuffix("_output") { return found(blocks: p["output"], call: p["call_id"] as? String) }
        return []
    }

    /// Claude Code and pi messages. A pi `toolResult` message answers its `toolCallId`.
    static func found(message m: [String: Any]) -> [Found] {
        found(blocks: m["content"], call: m["role"] as? String == "toolResult" ? m["toolCallId"] as? String : nil)
    }

    private static func found(blocks v: Any?, call: String?) -> [Found] {
        guard let blocks = v as? [[String: Any]] else { return [] }
        var out: [Found] = []
        for b in blocks {
            if let s = base64(of: b) { out.append(Found(base64: s, call: call)) }
            else if b["type"] as? String == "tool_result", let id = b["tool_use_id"] as? String {
                out += found(blocks: b["content"], call: id)
            }
        }
        return out
    }

    private static func base64(of b: [String: Any]) -> String? {
        switch b["type"] as? String {
        case "image":
            if let src = b["source"] as? [String: Any] { return src["type"] as? String == "base64" ? src["data"] as? String : nil }
            return b["data"] as? String
        case "input_image":
            guard let url = b["image_url"] as? String, url.hasPrefix("data:image/"), let comma = url.firstIndex(of: ","),
                  url[..<comma].hasSuffix(";base64") else { return nil }
            return String(url[url.index(after: comma)...])
        default: return nil
        }
    }

    /// Refs for the pictures whose header can be read; `index` still counts the others, as `data` does.
    static func refs(_ found: [Found], offset: UInt64?) -> [(call: String?, ref: Ref)] {
        found.enumerated().compactMap { i, f in
            header(base64: f.base64).map { (f.call, Ref(format: $0.format, width: $0.width, height: $0.height, offset: offset, index: i, digest: fingerprint(base64: f.base64))) }
        }
    }

    // MARK: reading back

    /// The bytes of the nth picture in a log line.
    public static func data(line: String, index: Int) -> Data? { data(lineData: Data(line.utf8), index: index) }

    static func data(lineData: Data, index: Int) -> Data? {
        base64(lineData: lineData, index: index).flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
    }

    static func base64(lineData: Data, index: Int) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { return nil }
        let f = found(in: o)
        return f.indices.contains(index) ? f[index].base64 : nil
    }

    /// The picture `ref` points at in the log file. Nil unless `offset` starts a line and the picture there still has the
    /// ref's fingerprint, format and size (a rewritten log does not show another picture).
    public static func read(_ ref: Ref, from url: URL) -> Data? {
        guard let offset = ref.offset, let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        do {
            if offset > 0 {
                try fh.seek(toOffset: offset - 1)
                guard try fh.read(upToCount: 1) == Data([0x0a]) else { return nil }
            }
            var line = Data()
            while line.count < maxLine, let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty {
                if let nl = chunk.firstIndex(of: 0x0a) { line += chunk[chunk.startIndex..<nl]; break }
                line += chunk
            }
            guard let b64 = base64(lineData: line, index: ref.index), fingerprint(base64: b64) == ref.digest,
                  let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), let h = header(d),
                  h.format == ref.format, h.width == ref.width, h.height == ref.height else { return nil }
            return d
        } catch { return nil }
    }
}
