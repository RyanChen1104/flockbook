import Foundation
import Network

/// `flockbook-notify`'s way into the app: `POST /notify` on 127.0.0.1 only, with a bearer token kept in a mode-600
/// file (`Info`: port and token) that only the owner's processes can read. A request from a browser (an `Origin`
/// header) is refused. The body is JSON {title, body?, pane?}; the notice goes to `handle`, which returns the phones
/// reached.
@MainActor public final class NotifyEndpoint {
    public struct Info: Codable, Hashable, Sendable { public var port: UInt16; public var token: String }
    public enum Parsed: Sendable { case incomplete, reply(Int, String), notice(PushNotice) }
    public static let maxRequest = 8192
    private let handle: @MainActor (PushNotice) async -> Int
    private var listener: NWListener?
    private var token = ""

    public init(handle: @escaping @MainActor (PushNotice) async -> Int) { self.handle = handle }

    /// One request so far. `incomplete`: read more.
    public static func parse(_ data: Data, token: String) -> Parsed {
        guard data.count < maxRequest else { return .reply(413, "Too big.") }
        guard let split = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        let lines = String(decoding: data[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let body = data[split.upperBound...]
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else { return .reply(400, "Bad length.") }
        guard body.count >= length else { return .incomplete }
        guard lines.first?.hasPrefix("POST /notify ") == true else { return .reply(405, "Only POST /notify.") }
        guard headers["origin"] == nil else { return .reply(403, "Not from a browser.") }
        let given = Data((headers["authorization"] ?? "").utf8), want = Data("Bearer \(token)".utf8)
        // Same time for every wrong token of the same length.
        guard !token.isEmpty, given.count == want.count, zip(given, want).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else {
            return .reply(401, "Wrong token.")
        }
        guard let o = try? JSONSerialization.jsonObject(with: body.prefix(length)) as? [String: Any] else { return .reply(400, "Not JSON.") }
        let title = (o["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return .reply(400, "A title is needed.") }
        let pane = (o["pane"] as? String).flatMap { $0.isEmpty || $0.count > 200 ? nil : $0 }
        return .notice(PushNotice(title: title, body: (o["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                  tag: pane ?? "notify", pane: pane))
    }

    /// Listens on 127.0.0.1 (a free port) with a new token, and writes both to `file` (mode 600).
    public func start(file: URL) async throws -> Info {
        stop()
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: p)
        l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.serve(c) } }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let once = Once()
            l.stateUpdateHandler = { s in
                switch s {
                case .ready: if once.first() { cont.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e): if once.first() { cont.resume(throwing: e) }
                case .cancelled: if once.first() { cont.resume(throwing: CocoaError(.userCancelled)) }
                default: break
                }
            }
            l.start(queue: .main)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { l.cancel(); throw CocoaError(.fileWriteUnknown) }
        token = Base64URL.encode(Data(bytes))
        listener = l
        let info = Info(port: port, token: token)
        do { try PrivateFile.write(try JSONEncoder().encode(info), to: file) } catch { stop(); throw error }
        return info
    }

    public func stop() { listener?.cancel(); listener = nil; token = "" }

    private func serve(_ c: NWConnection) {
        c.start(queue: .main)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ so: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequest) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { c.cancel(); return }
                let all = so + (data ?? Data())
                switch Self.parse(all, token: self.token) {
                case .incomplete:
                    if done || error != nil { c.cancel() } else { self.read(c, all) }
                case .reply(let status, let why):
                    self.reply(c, status, ["error": why])
                case .notice(let n):
                    let phones = await self.handle(n)
                    self.reply(c, 200, ["sent": phones])
                }
            }
        }
    }

    private func reply(_ c: NWConnection, _ status: Int, _ body: [String: Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + json, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// True once.
private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

/// The CLI's side: reads the info file, posts the message to 127.0.0.1.
public enum NotifyClient {
    public enum Failure: Error, Equatable { case notRunning, refused(Int, String) }

    /// The phones reached. `notRunning`: no info file, or nothing listens on its port (the app is not running, or
    /// Remote access is off).
    public static func send(title: String, body: String, pane: String?, file: URL) async throws -> Int {
        guard let data = try? Data(contentsOf: file), let info = try? JSONDecoder().decode(NotifyEndpoint.Info.self, from: data),
              let url = URL(string: "http://127.0.0.1:\(info.port)/notify") else { throw Failure.notRunning }
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.httpMethod = "POST"
        r.setValue("Bearer \(info.token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var o: [String: String] = ["title": title, "body": body]
        if let pane { o["pane"] = pane }
        r.httpBody = try JSONSerialization.data(withJSONObject: o)
        let s = URLSession(configuration: .ephemeral)
        defer { s.invalidateAndCancel() }
        let (answer, response): (Data, URLResponse)
        do { (answer, response) = try await s.data(for: r) } catch { throw Failure.notRunning }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONSerialization.jsonObject(with: answer) as? [String: Any]) ?? [:]
        guard status == 200 else { throw Failure.refused(status, j["error"] as? String ?? "") }
        return j["sent"] as? Int ?? 0
    }
}
