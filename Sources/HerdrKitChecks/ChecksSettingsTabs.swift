import Foundation
@testable import HerdrKit

/// The Settings page's tabs: their order and names, which tab holds each control (every control in exactly one),
/// and the remembered tab (an unknown or missing value opens General).
func checksSettingsTabs() async throws {
    check(SettingsTab.allCases == [.general, .agents, .remote, .updates], "settings tabs: General, Agents, Remote, Updates in this order")
    check(SettingsTab.allCases.map(\.title) == ["General", "Agents", "Remote", "Updates"], "settings tabs: titles")
    check(Set(SettingsTab.allCases.map(\.symbol)).count == SettingsTab.allCases.count && SettingsTab.allCases.allSatisfy { !$0.symbol.isEmpty },
          "settings tabs: each has its own symbol")

    let placed = SettingsTab.allCases.flatMap(\.controls)
    check(placed.count == Set(placed).count, "settings tabs: no control is in two tabs (\(placed.map(\.rawValue)))")
    check(Set(placed) == Set(SettingsControl.allCases), "settings tabs: every control is in a tab (missing \(Set(SettingsControl.allCases).subtracting(placed).map(\.rawValue)))")
    check(SettingsTab.allCases.allSatisfy { !$0.controls.isEmpty }, "settings tabs: no empty tab")
    check(SettingsTab.general.controls == [.window, .textSize, .readingWidth], "settings tabs: General holds the window look and reading")
    check(SettingsTab.agents.controls == [.allowInput, .claudeQuestions], "settings tabs: Agents holds input and the Claude question hook")
    check(SettingsTab.remote.controls == [.remoteAccess, .connectWith, .tailscaleSteps, .address, .devices, .pictures, .phoneNotifications, .agentCommand],
          "settings tabs: Remote holds pairing, pictures and notifications")
    check(SettingsTab.updates.controls == [.autoUpdate, .version], "settings tabs: Updates holds automatic updates and the version")
    check(SettingsControl.allCases.allSatisfy { c in SettingsTab.tab(of: c).controls.contains(c) }, "settings tabs: tab(of:) finds each control's tab")

    check(SettingsTab.key == "settingsTab", "settings tabs: remembered under settingsTab")
    check(SettingsTab(stored: "remote") == .remote && SettingsTab(stored: "updates") == .updates, "settings tabs: a stored tab comes back")
    check(SettingsTab(stored: nil) == .general, "settings tabs: nothing stored opens General")
    check(SettingsTab(stored: "") == .general && SettingsTab(stored: "Remote") == .general && SettingsTab(stored: "privacy") == .general,
          "settings tabs: an unknown stored value opens General")
}
