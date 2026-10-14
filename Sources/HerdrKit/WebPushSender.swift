import CryptoKit
import Foundation

/// A phone's push subscription (from the PWA's `PushManager.subscribe`), bound to the paired device that sent it.
public struct PushSubscription: Codable, Hashable, Sendable {
    /// The hub device id (`HubDevice.id`): removing the device removes its subscriptions.
    public var device: String
    public var endpoint: String
    /// The subscription's keys, base64url: `p256dh` (65-byte P-256 point) and `auth` (16 bytes).
    public var p256dh: String
    public var auth: String
    public var added: Date
    public init(device: String, endpoint: String, p256dh: String, auth: String, added: Date = Date()) {
        self.device = device; self.endpoint = endpoint; self.p256dh = p256dh; self.auth = auth; self.added = added
    }

    /// Only an https endpoint of a known push service: a paired device must not make the Mac post to any URL.
    /// Keys must decode to the right sizes.
    public var isValid: Bool {
        guard Self.allowedEndpoint(endpoint), Base64URL.decode(p256dh)?.count == 65, Base64URL.decode(auth)?.count == 16 else { return false }
        return true
    }

    /// Push services of Chrome / Android (FCM), Safari / iOS (Apple), Firefox (Mozilla) and Edge (Windows).
    public static let pushHosts = ["fcm.googleapis.com", "android.googleapis.com", "push.apple.com", "push.services.mozilla.com", "notify.windows.com"]

    public static func allowedEndpoint(_ s: String) -> Bool {
        guard s.count <= 2048, let u = URL(string: s), u.scheme == "https", u.user == nil, u.port == nil || u.port == 443,
              let host = u.host?.lowercased() else { return false }
        return pushHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// What a push service said about one message.
public enum PushOutcome: Sendable, Hashable {
    case sent
    /// 404 or 410: the subscription is gone (the phone unsubscribed or the browser dropped it). Delete it.
    case gone
    /// Any other status (0: no answer). Keep the subscription.
    case failed(Int)
}

public enum WebPushSender {
    public enum Urgency: String, Sendable { case normal, high }
    /// The VAPID contact every push service sees: the project page. Never the hub's own address (that would hand the
    /// owner's ts.net host name to Google and Apple); a placeholder domain may be refused by Apple.
    public static let subject = "https://github.com/minchenlee/flockbook"

    /// Posts the request and returns its HTTP status (0: no answer).
    public typealias Transport = @Sendable (URLRequest) async -> Int

    /// The POST for one message: encrypted body, VAPID, TTL and Urgency.
    public static func request(_ payload: Data, to s: PushSubscription, key: P256.Signing.PrivateKey, subject: String,
                               urgency: Urgency, ttl: Int = 3600, now: Date = Date()) throws -> URLRequest {
        guard let url = URL(string: s.endpoint), let scheme = url.scheme, let host = url.host,
              let ua = Base64URL.decode(s.p256dh), let auth = Base64URL.decode(s.auth) else { throw WebPushError.badKey }
        let body = try WebPush.encrypt(payload, uaPublic: ua, authSecret: auth)
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.httpMethod = "POST"
        r.httpBody = body
        r.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.setValue(String(ttl), forHTTPHeaderField: "TTL")
        r.setValue(urgency.rawValue, forHTTPHeaderField: "Urgency")
        let origin = scheme + "://" + host + (url.port.map { ":\($0)" } ?? "")
        r.setValue(VAPID.authorization(audience: origin, subject: subject, key: key, now: now), forHTTPHeaderField: "Authorization")
        return r
    }

    /// Sends one message. Refuses an endpoint off the allow list (`PushSubscription.isValid`): nothing is contacted.
    public static func send(_ payload: Data, to s: PushSubscription, key: P256.Signing.PrivateKey, subject: String,
                            urgency: Urgency) async -> PushOutcome {
        guard s.isValid else { return .failed(0) }
        return await send(payload, to: s, key: key, subject: subject, urgency: urgency, unchecked: urlSession)
    }

    /// Checks only (internal, reached through `@testable import`): sends through `unchecked` WITHOUT the allow list, to
    /// the local fake push service. App code cannot call it.
    static func send(_ payload: Data, to s: PushSubscription, key: P256.Signing.PrivateKey, subject: String,
                     urgency: Urgency, unchecked transport: Transport) async -> PushOutcome {
        guard let r = try? request(payload, to: s, key: key, subject: subject, urgency: urgency) else { return .failed(0) }
        let status = await transport(r)
        switch status {
        case 200..<300: return .sent
        case 404, 410: return .gone
        default: return .failed(status)
        }
    }

    public static let urlSession: Transport = { r in
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return 0 }
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }
}
