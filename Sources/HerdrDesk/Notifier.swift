import HerdrKit
import Foundation
import UserNotifications

/// System notifications for tabs that become blocked. Needs a real app bundle (UNUserNotificationCenter
/// crashes in an unbundled binary), so it does nothing under `swift run`.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var known: Set<String>?
    var onOpen: ((_ workspaceID: String, _ tabID: String) -> Void)?
    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    func start() {
        guard available else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Call on every workspace update. The first call only records the current state.
    func update(_ workspaces: [Workspace]) {
        var now: Set<String> = []
        var fresh: [(Workspace, Tab)] = []
        for ws in workspaces { for t in ws.tabs where t.status == .blocked {
            now.insert(t.id)
            if let known, !known.contains(t.id) { fresh.append((ws, t)) }
        } }
        let isFirst = known == nil
        known = now
        guard !isFirst, available else { return }
        for (ws, t) in fresh {
            let c = UNMutableNotificationContent()
            c.title = t.primaryAgent?.name ?? t.label
            c.body = "Needs you · \(ws.label) · \(t.label)"
            c.sound = .default
            c.userInfo = ["ws": ws.id, "tab": t.id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "blocked-\(t.id)", content: c, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let ws = info["ws"] as? String, let tab = info["tab"] as? String else { return }
        await MainActor.run { onOpen?(ws, tab) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
