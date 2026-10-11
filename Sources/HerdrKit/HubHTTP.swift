import Foundation
import CryptoKit

// The hub's own small HTTP/1.1 + WebSocket (RFC 6455) layer. Network.framework's WebSocket protocol can only take
// an upgrade; the PWA's files must come from the same origin as the socket, so the hub reads the request itself:
// `GET /ws` with an upgrade becomes the socket, other GETs get a file (then the connection closes).

/// A parsed request head.
public struct HTTPHead: Equatable, Sendable {
    public var method: String
    /// Without the query.
    public var path: String
    public var headers: [(String, String)]

    public static func == (a: HTTPHead, b: HTTPHead) -> Bool {
        a.method == b.method && a.path == b.path && a.headers.map { $0.0 + ":" + $0.1 } == b.headers.map { $0.0 + ":" + $0.1 }
    }

    public func header(_ name: String) -> String? { headers.first { $0.0.lowercased() == name.lowercased() }?.1 }

    /// Largest head taken.
    public static let maxHead = 16 * 1024

    /// The head up to the blank line, or nil when it is not a valid HTTP/1.x request head.
    public static func parse(_ data: Data) -> HTTPHead? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2].hasPrefix("HTTP/1."), first[1].hasPrefix("/") else { return nil }
        var headers: [(String, String)] = []
        for l in lines where !l.isEmpty {
            guard let i = l.firstIndex(of: ":") else { return nil }
            headers.append((String(l[..<i]).trimmingCharacters(in: .whitespaces), String(l[l.index(after: i)...]).trimmingCharacters(in: .whitespaces)))
        }
        let target = String(first[1])
        return HTTPHead(method: String(first[0]), path: String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]), headers: headers)
    }

    /// The end of the head (index after the blank line) in `data`, if it is there.
    static func end(in data: Data) -> Data.Index? {
        data.range(of: Data("\r\n\r\n".utf8)).map(\.upperBound)
    }

    static func response(_ status: String, type: String? = nil, body: Data = Data(), extra: [(String, String)] = []) -> Data {
        var h = "HTTP/1.1 \(status)\r\n"
        var all = extra
        if let type { all.append(("Content-Type", type)) }
        all.append(("Content-Length", "\(body.count)"))
        all.append(("Connection", "close"))
        for (k, v) in all { h += "\(k): \(v)\r\n" }
        return Data((h + "\r\n").utf8) + body
    }
}

/// Client-to-hub frame reading and hub-to-client frame writing.
public struct WebSocketFrames: Sendable {
    public enum Event: Equatable, Sendable {
        /// A whole text or binary message.
        case message(Data)
        case ping(Data)
        case close
        /// A protocol error: close with this code.
        case fail(UInt16)
    }

    private var buffer = Data()
    private var partial: Data?
    private let maxMessage: Int
    private var failed = false

    public init(maxMessage: Int) { self.maxMessage = maxMessage }

    public static func accept(key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    /// Takes the next bytes from the client; returns the events they complete.
    public mutating func feed(_ data: Data) -> [Event] {
        guard !failed else { return [] }
        buffer.append(data)
        var out: [Event] = []
        while true {
            let b = [UInt8](buffer.prefix(14))
            guard b.count >= 2 else { break }
            let fin = b[0] & 0x80 != 0, opcode = b[0] & 0x0f
            let masked = b[1] & 0x80 != 0
            var len = Int(b[1] & 0x7f), at = 2
            if len == 126 { guard b.count >= 4 else { break }; len = Int(b[2]) << 8 | Int(b[3]); at = 4 }
            else if len == 127 {
                guard b.count >= 10 else { break }
                var l: UInt64 = 0
                for i in 2..<10 { l = l << 8 | UInt64(b[i]) }
                guard l <= UInt64(maxMessage) else { return fail(1009, out) }
                len = Int(l); at = 10
            }
            guard masked, b[0] & 0x70 == 0 else { return fail(1002, out) }      // no extensions: RSV bits must be 0
            if opcode >= 8 { guard fin, len <= 125 else { return fail(1002, out) } }
            if len > maxMessage || (partial?.count ?? 0) + len > maxMessage { return fail(1009, out) }
            guard buffer.count >= at + 4 + len else { break }
            let start = buffer.startIndex
            let key = [UInt8](buffer[(start + at)..<(start + at + 4)])
            var payload = [UInt8](buffer[(start + at + 4)..<(start + at + 4 + len)])
            for i in payload.indices { payload[i] ^= key[i % 4] }
            buffer = Data(buffer[(start + at + 4 + len)...])
            switch opcode {
            case 0:
                guard partial != nil else { return fail(1002, out) }
                partial!.append(contentsOf: payload)
                if fin { out.append(.message(partial!)); partial = nil }
            case 1, 2:
                guard partial == nil else { return fail(1002, out) }
                if fin { out.append(.message(Data(payload))) } else { partial = Data(payload) }
            case 8: out.append(.close); failed = true; return out
            case 9: out.append(.ping(Data(payload)))
            case 10: break
            default: return fail(1002, out)
            }
        }
        return out
    }

    private mutating func fail(_ code: UInt16, _ out: [Event]) -> [Event] { failed = true; return out + [.fail(code)] }

    /// A hub frame (FIN, not masked).
    public static func encode(opcode: UInt8, _ payload: Data) -> Data {
        var f = Data([0x80 | opcode])
        if payload.count < 126 { f.append(UInt8(payload.count)) }
        else if payload.count < 65536 { f.append(126); f.append(UInt8(payload.count >> 8)); f.append(UInt8(payload.count & 0xff)) }
        else { f.append(127); for i in (0..<8).reversed() { f.append(UInt8((payload.count >> (8 * i)) & 0xff)) } }
        return f + payload
    }
    public static func close(_ code: UInt16) -> Data { encode(opcode: 8, Data([UInt8(code >> 8), UInt8(code & 0xff)])) }
}

/// The PWA's files, served by the hub.
public enum HubWeb {
    public struct File: Sendable {
        public var type: String
        public var body: Data
        public init(type: String, body: Data) { self.type = type; self.body = body }
    }
    public struct Assets: Sendable {
        public var files: [String: File]
        public init(files: [String: File]) { self.files = files }
        /// `path` as requested ("/" = index.html). Only names in the table: no file system, no traversal.
        public func file(_ path: String) -> File? {
            let name = path == "/" ? "index.html" : String(path.dropFirst())
            return files[name]
        }
    }
    /// Sent with every file. `connect-src 'self'` covers the hub's own wss:// origin.
    public static let headers: [(String, String)] = [
        ("Content-Security-Policy", "default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
        ("Cache-Control", "no-cache"),
    ]
}
