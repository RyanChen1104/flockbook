import CryptoKit
import Foundation
import Network
@testable import HerdrKit

/// A push service on 127.0.0.1: records each request (headers, body) and answers with `status`.
final class FakePushService: @unchecked Sendable {
    struct Seen { var head: [String: String]; var body: Data }
    private let listener: NWListener
    private let lock = NSLock()
    private var _seen: [Seen] = []
    var status = 201
    /// Sent as `Location` (a redirect) when set.
    var location: String?
    /// Seconds before the answer.
    var delay: Double = 0
    var seen: [Seen] { lock.withLock { _seen } }
    var port: Int { Int(listener.port?.rawValue ?? 0) }

    init() throws {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 0)
        listener = try NWListener(using: p)
        listener.newConnectionHandler = { [weak self] c in
            c.start(queue: .global())
            self?.read(c, Data())
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
    }

    private func read(_ c: NWConnection, _ got: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, done, _ in
            guard let self else { return }
            let all = got + (d ?? Data())
            if let end = all.firstRange(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: all[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                var head: [String: String] = ["_line": lines.first ?? ""]
                for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { head[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
                let need = Int(head["content-length"] ?? "0") ?? 0
                let body = all[end.upperBound...]
                if body.count >= need {
                    self.lock.withLock { self._seen.append(Seen(head: head, body: Data(body.prefix(need)))) }
                    let loc = self.location.map { "Location: \($0)\r\n" } ?? ""
                    let resp = "HTTP/1.1 \(self.status) X\r\n\(loc)Content-Length: 0\r\nConnection: close\r\n\r\n"
                    DispatchQueue.global().asyncAfter(deadline: .now() + self.delay) {
                        c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in c.cancel() })
                    }
                    return
                }
            }
            if done { c.cancel(); return }
            self.read(c, all)
        }
    }
    func stop() { listener.cancel() }
}

func checksPushSender() async throws {
    // Allow list: only https endpoints of known push services.
    let ok = ["https://fcm.googleapis.com/fcm/send/abc", "https://web.push.apple.com/QK7", "https://updates.push.services.mozilla.com/wpush/v2/x",
              "https://wns2-par02p.notify.windows.com/w/?token=x"]
    let bad = ["http://fcm.googleapis.com/fcm/send/abc", "https://fcm.googleapis.com.evil.example/x", "https://evil.example/fcm.googleapis.com",
               "https://127.0.0.1/x", "https://user@fcm.googleapis.com/x", "https://fcm.googleapis.com:8443/x", "file:///etc/passwd", "notaurl"]
    check(ok.allSatisfy(PushSubscription.allowedEndpoint), "push: known push services allowed")
    for b in bad { check(!PushSubscription.allowedEndpoint(b), "push: endpoint refused: \(b)") }

    let phone = P256.KeyAgreement.PrivateKey()
    let auth = Data((0..<16).map { UInt8($0) })
    let svc = try FakePushService()
    defer { svc.stop() }
    let sub = PushSubscription(device: "d1", endpoint: "http://127.0.0.1:\(svc.port)/push/abc",
                               p256dh: Base64URL.encode(phone.publicKey.x963Representation), auth: Base64URL.encode(auth))
    check(!sub.isValid, "push: a loopback endpoint is not a valid subscription")
    let key = P256.Signing.PrivateKey()
    let payload = Data(#"{"title":"orchard-api-dev","body":"Needs you"}"#.utf8)
    check(await WebPushSender.send(payload, to: sub, key: key, subject: "mailto:a@b.c", urgency: .high) == .failed(0),
          "push: an endpoint off the allow list is not contacted")
    check(svc.seen.isEmpty, "push: nothing reached the fake service")

    let out = await WebPushSender.send(payload, to: sub, key: key, subject: "mailto:a@b.c", urgency: .high, unchecked: WebPushSender.urlSession)
    check(out == .sent, "push: 201 -> sent (\(out))")
    if let r = svc.seen.last {
        check(r.head["_line"] == "POST /push/abc HTTP/1.1", "push: POST to the endpoint path (\(r.head["_line"] ?? ""))")
        check(r.head["content-encoding"] == "aes128gcm" && r.head["ttl"] == "3600" && r.head["urgency"] == "high", "push: coding, TTL, Urgency headers")
        check(r.head["authorization"]?.hasPrefix("vapid t=") == true && r.head["authorization"]?.contains(", k=" + Base64URL.encode(key.publicKey.x963Representation)) == true,
              "push: VAPID authorization with the hub's key")
        check((try? WebPush.decrypt(r.body, uaPrivate: phone, authSecret: auth)) == payload, "push: the phone decrypts the body")
        check(!r.body.contains(Data("orchard".utf8)), "push: the text is not in the clear")
    } else { check(false, "push: the fake service got the request") }
    _ = await WebPushSender.send(payload, to: sub, key: key, subject: "mailto:a@b.c", urgency: .normal, unchecked: WebPushSender.urlSession)
    check(svc.seen.last?.head["urgency"] == "normal", "push: normal urgency for a done agent")
    svc.status = 410
    check(await WebPushSender.send(payload, to: sub, key: key, subject: "mailto:a@b.c", urgency: .high, unchecked: WebPushSender.urlSession) == .gone, "push: 410 -> gone")
    svc.status = 404
    check(await WebPushSender.send(payload, to: sub, key: key, subject: "mailto:a@b.c", urgency: .high, unchecked: WebPushSender.urlSession) == .gone, "push: 404 -> gone")
    svc.status = 429
    check(await WebPushSender.send(payload, to: sub, key: key, subject: "mailto:a@b.c", urgency: .high, unchecked: WebPushSender.urlSession) == .failed(429), "push: 429 -> kept, failed")

    // A redirect is never followed: it would take the POST past the allow list.
    let elsewhere = try FakePushService()
    defer { elsewhere.stop() }
    for code in [301, 302, 307, 308] {
        svc.status = code; svc.location = "http://127.0.0.1:\(elsewhere.port)/stolen"
        let r = await WebPushSender.send(payload, to: sub, key: key, subject: "mailto:a@b.c", urgency: .high, unchecked: WebPushSender.urlSession)
        check(r == .failed(code) && elsewhere.seen.isEmpty, "push: \(code) redirect -> failed, not followed (\(r), \(elsewhere.seen.count) at the other host)")
    }
    svc.location = nil

    // Cancelled: a request already sent is dropped at once; a task cancelled before sending sends nothing.
    svc.status = 201; svc.delay = 5
    let t0 = Date()
    let slow = Task { await WebPushSender.send(payload, to: sub, key: key, subject: "mailto:a@b.c", urgency: .high, unchecked: WebPushSender.urlSession) }
    try? await Task.sleep(for: .milliseconds(400))
    slow.cancel()
    let slowOut = await slow.value
    check(slowOut == .failed(0) && Date().timeIntervalSince(t0) < 2, "push: cancel -> the URLSession request stops (\(slowOut), \(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
    svc.delay = 0
    let before = svc.seen.count
    let early = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await WebPushSender.send(payload, to: sub, key: key, subject: "mailto:a@b.c", urgency: .high, unchecked: WebPushSender.urlSession)
    }
    let earlyOut = await early.value
    try? await Task.sleep(for: .milliseconds(200))
    check(earlyOut == .failed(0) && svc.seen.count == before, "push: cancelled before sending -> no request (\(svc.seen.count - before))")

    // The VAPID audience is the endpoint's origin: a default port is left out.
    func audience(_ endpoint: String) -> String? {
        let s = PushSubscription(device: "d", endpoint: endpoint, p256dh: Base64URL.encode(phone.publicKey.x963Representation), auth: Base64URL.encode(auth))
        guard let a = try? WebPushSender.request(payload, to: s, key: key, subject: "mailto:a@b.c", urgency: .high).value(forHTTPHeaderField: "Authorization"),
              let part = a.split(separator: ",").first?.split(separator: ".").dropFirst().first,
              let claims = Base64URL.decode(String(part)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: claims) as? [String: Any])?["aud"] as? String
    }
    check(audience("https://fcm.googleapis.com:443/fcm/send/x") == "https://fcm.googleapis.com", "push: aud leaves out :443 (\(audience("https://fcm.googleapis.com:443/fcm/send/x") ?? "nil"))")
    check(audience("https://web.push.apple.com/x") == "https://web.push.apple.com", "push: aud without a port")
    check(audience("http://127.0.0.1:8080/x") == "http://127.0.0.1:8080", "push: aud keeps a port that is not the default")
}
