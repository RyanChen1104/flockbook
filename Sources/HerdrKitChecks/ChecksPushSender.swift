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
                    let resp = "HTTP/1.1 \(self.status) X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in c.cancel() })
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

    let out = await WebPushSender.send(payload, to: sub, key: key, subject: "mailto:a@b.c", urgency: .high, transport: WebPushSender.urlSession)
    check(out == .sent, "push: 201 -> sent (\(out))")
    if let r = svc.seen.last {
        check(r.head["_line"] == "POST /push/abc HTTP/1.1", "push: POST to the endpoint path (\(r.head["_line"] ?? ""))")
        check(r.head["content-encoding"] == "aes128gcm" && r.head["ttl"] == "3600" && r.head["urgency"] == "high", "push: coding, TTL, Urgency headers")
        check(r.head["authorization"]?.hasPrefix("vapid t=") == true && r.head["authorization"]?.contains(", k=" + Base64URL.encode(key.publicKey.x963Representation)) == true,
              "push: VAPID authorization with the hub's key")
        check((try? WebPush.decrypt(r.body, uaPrivate: phone, authSecret: auth)) == payload, "push: the phone decrypts the body")
        check(!r.body.contains(Data("orchard".utf8)), "push: the text is not in the clear")
    } else { check(false, "push: the fake service got the request") }
    _ = await WebPushSender.send(payload, to: sub, key: key, subject: "mailto:a@b.c", urgency: .normal, transport: WebPushSender.urlSession)
    check(svc.seen.last?.head["urgency"] == "normal", "push: normal urgency for a done agent")
    svc.status = 410
    check(await WebPushSender.send(payload, to: sub, key: key, subject: "mailto:a@b.c", urgency: .high, transport: WebPushSender.urlSession) == .gone, "push: 410 -> gone")
    svc.status = 404
    check(await WebPushSender.send(payload, to: sub, key: key, subject: "mailto:a@b.c", urgency: .high, transport: WebPushSender.urlSession) == .gone, "push: 404 -> gone")
    svc.status = 429
    check(await WebPushSender.send(payload, to: sub, key: key, subject: "mailto:a@b.c", urgency: .high, transport: WebPushSender.urlSession) == .failed(429), "push: 429 -> kept, failed")
}
