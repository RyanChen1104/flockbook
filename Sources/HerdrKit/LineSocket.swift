import Foundation
import Darwin

public enum HerdrError: Error, Sendable, CustomStringConvertible {
    case socket(String)
    case server(code: String, message: String)
    case protocolError(String)
    case closed

    public var description: String {
        switch self {
        case .socket(let m): "socket: \(m)"
        case .server(let c, let m): "server error \(c): \(m)"
        case .protocolError(let m): "protocol: \(m)"
        case .closed: "connection closed"
        }
    }
}

/// Blocking NDJSON connection over a Unix socket. Call from a background task only.
final class LineSocket: @unchecked Sendable {
    private var fd: Int32
    private var buffer = [UInt8]()

    /// `timeout`: seconds for each read and write. nil blocks forever (event streams).
    init(path: String, timeout: TimeInterval? = nil) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrError.socket("socket() failed: \(errno)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { Darwin.close(fd); throw HerdrError.socket("path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            throw HerdrError.socket("connect \(path) failed: errno \(e)")
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if let timeout {
            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    func writeLine(_ data: Data) throws {
        var out = data
        out.append(0x0A)
        try out.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var sent = 0
            while sent < p.count {
                let n = Darwin.write(fd, p.baseAddress! + sent, p.count - sent)
                if n < 0 { if errno == EINTR { continue }; throw HerdrError.socket("write errno \(errno)") }
                sent += n
            }
        }
    }

    /// Next full line, or throws `.closed` at EOF.
    func readLine() throws -> Data {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<nl])
                buffer.removeSubrange(...nl)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0 { if errno == EINTR { continue }; throw HerdrError.socket("read errno \(errno)") }
            if n == 0 { throw HerdrError.closed }
            buffer.append(contentsOf: chunk[..<n])
        }
    }

    func close() {
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd); fd = -1 }
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }
}
