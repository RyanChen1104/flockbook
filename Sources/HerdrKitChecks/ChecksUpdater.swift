import Foundation
@testable import HerdrKit

/// When the app starts Sparkle: only an installed app bundle with a public key and an https feed, never a check run.
/// Anything else would make Sparkle show its "updater failed to start" alert.
func checksUpdater() async throws {
    let key = Data(repeating: 7, count: 32).base64EncodedString()
    let feed = "https://flockbook.example/appcast.xml"
    let app = "/Applications/Flockbook.app"
    func info(key: String? = key, feed: String? = feed) -> [String: Any] {
        var d: [String: Any] = [:]
        if let key { d["SUPublicEDKey"] = key }
        if let feed { d["SUFeedURL"] = feed }
        return d
    }
    check(UpdaterGate.decide(bundlePath: app, info: info(), headless: false) == .start, "updater: app bundle with key and https feed starts")
    check(UpdaterGate.decide(bundlePath: app + "/", info: info(), headless: false) == .start, "updater: trailing slash on the bundle path")
    check(UpdaterGate.decide(bundlePath: app, info: info(), headless: true) != .start, "updater: headless check runs never start it")
    check(UpdaterGate.decide(bundlePath: "/work/flockbook/.build/debug", info: info(), headless: false) != .start, "updater: swift run (no app bundle) does not start it")
    check(UpdaterGate.decide(bundlePath: app, info: info(key: nil), headless: false) != .start, "updater: no SUPublicEDKey")
    check(UpdaterGate.decide(bundlePath: app, info: info(key: ""), headless: false) != .start, "updater: empty SUPublicEDKey (build var unset)")
    check(UpdaterGate.decide(bundlePath: app, info: info(key: "not base64!"), headless: false) != .start, "updater: SUPublicEDKey not base64")
    check(UpdaterGate.decide(bundlePath: app, info: info(key: Data(count: 31).base64EncodedString()), headless: false) != .start, "updater: SUPublicEDKey not 32 bytes")
    check(UpdaterGate.decide(bundlePath: app, info: info(feed: nil), headless: false) != .start, "updater: no SUFeedURL")
    check(UpdaterGate.decide(bundlePath: app, info: info(feed: "http://flockbook.example/appcast.xml"), headless: false) != .start, "updater: plain http feed")
    check(UpdaterGate.decide(bundlePath: app, info: info(feed: "https:///appcast.xml"), headless: false) != .start, "updater: feed without a host")
    if case let .off(why) = UpdaterGate.decide(bundlePath: app, info: info(key: ""), headless: false) {
        check(why.contains("SUPublicEDKey"), "updater: the reason names the missing key")
    } else { check(false, "updater: empty key gives a reason") }

    // The bundle's Info.plist: Sparkle checks every hour (its shortest interval), by itself, without the first-launch prompt.
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bundle = (try? String(contentsOf: root.appending(path: "scripts/bundle.sh"), encoding: .utf8)) ?? ""
    func plistValue(_ key: String) -> String? {
        guard let r = bundle.range(of: "<key>\(key)</key><[^>]+>[^<]*", options: .regularExpression) else { return nil }
        return String(bundle[r].dropFirst("<key>\(key)</key>".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    check(plistValue("SUScheduledCheckInterval") == "<integer>3600", "updater: Info.plist SUScheduledCheckInterval is 3600 (\(plistValue("SUScheduledCheckInterval") ?? "missing"))")
    check(plistValue("SUEnableAutomaticChecks") == "<true/>", "updater: Info.plist SUEnableAutomaticChecks is true")
}
