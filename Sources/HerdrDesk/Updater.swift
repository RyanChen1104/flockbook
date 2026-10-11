import AppKit
import HerdrKit
import Sparkle
import SwiftUI

/// Auto-update through Sparkle. The feed (SUFeedURL) and the EdDSA public key (SUPublicEDKey) come from Info.plist,
/// which scripts/bundle.sh writes. UpdaterGate keeps Sparkle off in dev builds, builds without a key, and checks.
@MainActor @Observable final class AppUpdater {
    static let shared = AppUpdater()
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?
    /// False while a check or an update is in progress.
    private(set) var canCheck = false

    var updater: SPUUpdater? { controller?.updater }

    func start(quiet: Bool) {
        let decision = UpdaterGate.decide(bundlePath: Bundle.main.bundlePath, info: Bundle.main.infoDictionary ?? [:], headless: quiet)
        guard decision == .start else {
            if !quiet, case let .off(why) = decision { NSLog("Flockbook updates off: %@", why) }
            return
        }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = c
        canCheck = c.updater.canCheckForUpdates
        // Sparkle changes canCheckForUpdates on the main thread.
        observation = c.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            let can = change.newValue ?? false
            Task { @MainActor in self?.canCheck = can }
        }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// Sparkle keeps this in the app's standard defaults (SUEnableAutomaticChecks), next to Info.plist's default.
    var automaticallyChecks: Bool {
        get { access(keyPath: \.canCheck); return updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue; withMutation(keyPath: \.canCheck) {} }
    }
}

/// "Check for Updates…" under the app menu's About item. Absent when updates are off (dev builds).
struct UpdateCommands: Commands {
    let updater: AppUpdater
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updater.updater != nil {
                Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
            }
        }
    }
}

/// `--test-update <feed URL>`: a headless update run against a test feed. A user driver without UI accepts the
/// update, Sparkle downloads it, checks its EdDSA signature and replaces this app bundle, then quits without
/// relaunching (a relaunch would open a window). scripts/test-update.sh builds the bundles and the feed.
@MainActor final class HeadlessUpdateTest: NSObject {
    static var current: HeadlessUpdateTest?
    private let feed: String
    private var updater: SPUUpdater?

    init(feed: String) { self.feed = feed }

    static func run(feed: String) {
        let t = HeadlessUpdateTest(feed: feed)
        current = t
        t.begin()
    }

    private func say(_ s: String) { print("update-test: \(s)") }

    private func begin() {
        let b = Bundle.main
        say("app \(b.bundlePath) version \(b.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(b.infoDictionary?["CFBundleVersion"] ?? "?"))")
        // Same gate as the app, except the feed: the test feed is plain http on 127.0.0.1.
        let info = (b.infoDictionary ?? [:]).merging(["SUFeedURL": "https://test.invalid/appcast.xml"]) { _, new in new }
        if case let .off(why) = UpdaterGate.decide(bundlePath: b.bundlePath, info: info, headless: false) {
            say("FAIL gate: \(why)"); exit(1)
        }
        let u = SPUUpdater(hostBundle: b, applicationBundle: b, userDriver: HeadlessUserDriver(say: say), delegate: self)
        updater = u
        do { try u.start() } catch { say("FAIL start: \(error.localizedDescription)"); exit(1) }
        u.checkForUpdates()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(50))
            say("FAIL timeout"); exit(1)
        }
    }
}

extension HeadlessUpdateTest: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? { feed }
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { false }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        say("found \(item.displayVersionString) (\(item.versionString))")
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        say("no update: \((error as NSError).localizedDescription)"); exit(3)
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let e = error as NSError
        say("FAIL aborted: \(e.domain) \(e.code) \(e.localizedDescription) \(e.userInfo[NSUnderlyingErrorKey] ?? "")"); exit(2)
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { say("installing \(item.versionString)") }
}

/// Answers every Sparkle prompt without UI: yes to the update, install, no relaunch.
private final class HeadlessUserDriver: NSObject, SPUUserDriver {
    let say: @MainActor (String) -> Void
    private var installing = false
    init(say: @escaping @MainActor (String) -> Void) { self.say = say }
    private func log(_ s: String) { let say = say; Task { @MainActor in say(s) } }

    func show(_ request: SPUUpdatePermissionRequest) async -> SUUpdatePermissionResponse {
        SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false)
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { log("checking") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState) async -> SPUUserUpdateChoice {
        log("update found: \(appcastItem.displayVersionString), accepting"); return .install
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showUpdateNotFoundWithError(_ error: any Error) async { log("not found: \(error.localizedDescription)") }
    func showUpdaterError(_ error: any Error) async {
        let e = error as NSError
        log("error: \(e.domain) \(e.code) \(e.localizedDescription) \(e.userInfo[NSUnderlyingErrorKey] ?? "")")
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { log("download started") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { log("download size \(expectedContentLength)") }
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { log("download done, extracting") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice { log("ready to install"); installing = true; return .install }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        log("installing (app terminated: \(applicationTerminated))")
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async { log("installed, relaunched: \(relaunched)") }
    func showUpdateInFocus() {}
    func dismissUpdateInstallation() {
        log("dismissed")
        // Without a relaunch, Sparkle's installer replaces the bundle once the app quits.
        guard installing else { return }
        Task { @MainActor in
            print("update-test: quitting so the installer can replace the bundle")
            NSApp.terminate(nil)
        }
    }
}
