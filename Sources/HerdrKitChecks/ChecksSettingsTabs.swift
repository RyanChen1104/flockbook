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
    check(SettingsTab.general.controls == [.machines, .window, .textSize, .readingWidth, .terminalColors],
          "settings tabs: General holds the machine shown, the window look, reading and the terminal's colours")
    check(SettingsTab.agents.controls == [.allowInput, .statusLine, .claudeQuestions], "settings tabs: Agents holds input, the Claude status line and the question hook")
    check(SettingsTab.remote.controls == [.remoteAccess, .connectWith, .tailscaleSteps, .address, .devices, .pictures, .phoneNotifications, .agentCommand],
          "settings tabs: Remote holds pairing, pictures and notifications")
    check(SettingsTab.updates.controls == [.autoUpdate, .version], "settings tabs: Updates holds automatic updates and the version")
    check(SettingsControl.allCases.allSatisfy { c in SettingsTab.tab(of: c).controls.contains(c) }, "settings tabs: tab(of:) finds each control's tab")

    check(SettingsTab.key == "settingsTab", "settings tabs: remembered under settingsTab")
    check(SettingsTab(stored: "remote") == .remote && SettingsTab(stored: "updates") == .updates, "settings tabs: a stored tab comes back")
    check(SettingsTab(stored: nil) == .general, "settings tabs: nothing stored opens General")
    check(SettingsTab(stored: "") == .general && SettingsTab(stored: "Remote") == .general && SettingsTab(stored: "privacy") == .general,
          "settings tabs: an unknown stored value opens General")

    // Each page opens with its icon, its title and one line on what it is for.
    check(SettingsTab.allCases.allSatisfy { !$0.summary.isEmpty && !$0.summary.contains("\n") && $0.summary.count <= 60 && $0.summary.hasSuffix(".") },
          "settings tabs: each has a one-line summary (\(SettingsTab.allCases.map(\.summary)))")
    check(SettingsTab.remote.summary == "Use your agents from your phone.", "settings tabs: Remote's summary")

    // The Tailscale checks: all passed -> one row until Details; any not passed -> every step, those not passed first.
    let all = [true, true, true, true, true], some = [true, true, false, false, true]
    check(SetupChecks.collapsed(all, details: false), "setup checks: all passed -> one summary row")
    check(!SetupChecks.collapsed(all, details: true), "setup checks: all passed, Details -> every step")
    check(!SetupChecks.collapsed(some, details: false) && !SetupChecks.collapsed(some, details: true), "setup checks: one not passed -> every step, Details or not")
    check(SetupChecks.order(some) == [2, 3, 0, 1, 4], "setup checks: not passed first, each part in its own order (\(SetupChecks.order(some)))")
    check(SetupChecks.order(all) == [0, 1, 2, 3, 4] && SetupChecks.order([false, false]) == [0, 1], "setup checks: all alike -> the steps' own order")
    check(SetupChecks.summary(all) == "All 5 checks passed" && SetupChecks.summary(some) == "3 of 5 checks passed", "setup checks: the summary line (\(SetupChecks.summary(some)))")
}
