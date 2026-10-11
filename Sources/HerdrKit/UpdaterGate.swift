import Foundation

/// Decides whether the app may start Sparkle (auto-update). Sparkle shows an "updater failed to start" alert when
/// the bundle has no EdDSA public key, so a dev build (`swift run`, no app bundle), a build without the key, and
/// every headless check leave it off.
public enum UpdaterGate {
    public enum Decision: Equatable {
        case start
        case off(String)
    }

    public static func decide(bundlePath: String, info: [String: Any], headless: Bool) -> Decision {
        if headless { return .off("headless run") }
        let path = bundlePath.hasSuffix("/") ? String(bundlePath.dropLast()) : bundlePath
        guard path.hasSuffix(".app") else { return .off("not an app bundle: \(path)") }
        guard let key = info["SUPublicEDKey"] as? String, let raw = Data(base64Encoded: key), raw.count == 32 else {
            return .off("no valid SUPublicEDKey (32-byte EdDSA public key, base64)")
        }
        guard let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)), feed.scheme == "https",
              let host = feed.host(), !host.isEmpty else {
            return .off("no https SUFeedURL")
        }
        return .start
    }
}
