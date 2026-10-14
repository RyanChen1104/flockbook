import Foundation
@testable import HerdrKit

/// `flockbook-notify` -> the app: 127.0.0.1 only, a bearer token from a mode-600 file, a short message. Real loopback
/// sockets, a temp folder; nothing is pushed (a recording handler).
@MainActor func checksNotifyEndpoint() async {
    let dir = FileManager.default.temporaryDirectory.appending(path: "fb-notify-\(getpid())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appending(path: "hub/notify.json")
    func mode(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.posixPermissions] as? Int) ?? -1 }

    // Parsing alone: token, method, size, JSON.
    func req(_ body: String, token: String = "tok", extra: String = "", method: String = "POST /notify") -> Data {
        Data("\(method) HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\n\(extra)Content-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    }
    func status(_ r: NotifyEndpoint.Parsed) -> Int { if case .reply(let s, _) = r { s } else { -1 } }
    let good = NotifyEndpoint.parse(req(#"{"title":"Build done","body":"All green","pane":"w1:p2"}"#), token: "tok")
    if case .notice(let n) = good {
        check(n.title == "Build done" && n.body == "All green" && n.pane == "w1:p2" && n.tag == "w1:p2", "notify: a good request -> the notice")
    } else { check(false, "notify: a good request -> the notice (\(good))") }
    check(status(NotifyEndpoint.parse(req(#"{"title":"x"}"#, token: "nope"), token: "tok")) == 401, "notify: wrong token -> 401")
    check(status(NotifyEndpoint.parse(req(#"{"title":"x"}"#, extra: "Origin: https://evil.example\r\n"), token: "tok")) == 403, "notify: a browser (Origin) -> 403")
    check(status(NotifyEndpoint.parse(req("", method: "GET /notify"), token: "tok")) == 405, "notify: not POST /notify -> 405")
    check(status(NotifyEndpoint.parse(req(#"{"body":"no title"}"#), token: "tok")) == 400, "notify: no title -> 400")
    check(status(NotifyEndpoint.parse(req("not json"), token: "tok")) == 400, "notify: not JSON -> 400")
    let half = req(#"{"title":"x"}"#); 
    if case .incomplete = NotifyEndpoint.parse(half.prefix(half.count - 3), token: "tok") { check(true, "notify: half a request -> wait for more") }
    else { check(false, "notify: half a request -> wait for more") }
    let big = String(repeating: "b", count: 900)
    if case .notice(let n) = NotifyEndpoint.parse(req(#"{"title":"t","body":"\#(big)"}"#), token: "tok") {
        check(n.body.count == 200, "notify: the body is cut to 200 characters")
    } else { check(false, "notify: the body is cut to 200 characters") }
    check(status(NotifyEndpoint.parse(req(String(repeating: "x", count: NotifyEndpoint.maxRequest)), token: "tok")) == 413, "notify: too big -> 413")

    // Over loopback, with the client the CLI uses.
    check((try? await NotifyClient.send(title: "x", body: "", pane: nil, file: file)) == nil, "notify client: no file -> app not running")
    var got: [PushNotice] = []
    let e = NotifyEndpoint { n in got.append(n); return 2 }
    let info = try? await e.start(file: file)
    check(info != nil && mode(file) == 0o600, "notify: started, info file 600 (\(String(mode(file), radix: 8)))")
    let written = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(NotifyEndpoint.Info.self, from: $0) }
    check(written == info && (info?.token.count ?? 0) >= 40, "notify: the file holds the port and a long token")
    var sent: Int?
    do { sent = try await NotifyClient.send(title: "Deploy ready", body: "Tap to see", pane: "w1:p3", file: file) } catch { check(false, "notify client: \(error)") }
    check(sent == 2 && got.map(\.title) == ["Deploy ready"] && got.first?.pane == "w1:p3", "notify client: sent through the app (\(sent ?? -1) phones)")
    var refused: Error?
    do { _ = try await NotifyClient.send(title: "", body: "", pane: nil, file: file) } catch { refused = error }
    check((refused as? NotifyClient.Failure).map { if case .refused(400, _) = $0 { true } else { false } } == true, "notify client: an empty title is refused (\(String(describing: refused)))")
    e.stop()
    var down: Error?
    do { _ = try await NotifyClient.send(title: "x", body: "", pane: nil, file: file) } catch { down = error }
    check((down as? NotifyClient.Failure) == .notRunning, "notify client: endpoint stopped -> app not running (\(String(describing: down)))")
}
