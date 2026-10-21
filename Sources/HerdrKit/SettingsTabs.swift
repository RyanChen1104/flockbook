import Foundation

/// The Settings page's tabs, in sidebar order, like System Settings: what the app looks like (General), what Flockbook
/// may do to the agents (Agents), the phone (Remote), and updates. Each control of the page lives in exactly one tab.
public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, agents, remote, updates

    /// The defaults key of the tab Settings shows when it opens: the one chosen last.
    public static let key = "settingsTab"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .agents: "Agents"
        case .remote: "Remote"
        case .updates: "Updates"
        }
    }

    /// SF Symbol of the tab's icon.
    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .agents: "terminal"
        case .remote: "iphone"
        case .updates: "arrow.down.circle"
        }
    }

    /// The controls the tab shows, top to bottom. Some show only in a state (Connect with: Remote access on).
    public var controls: [SettingsControl] {
        switch self {
        case .general: [.window, .textSize, .readingWidth]
        case .agents: [.allowInput, .statusLine, .claudeQuestions]
        case .remote: [.remoteAccess, .connectWith, .tailscaleSteps, .address, .devices, .pictures, .phoneNotifications, .agentCommand]
        case .updates: [.autoUpdate, .version]
        }
    }

    /// The tab that holds `control`.
    public static func tab(of control: SettingsControl) -> SettingsTab {
        allCases.first { $0.controls.contains(control) } ?? .general
    }

    /// The remembered tab; nothing stored or an unknown value: General.
    public init(stored: String?) {
        self = stored.flatMap(SettingsTab.init(rawValue:)) ?? .general
    }
}

/// One control (row) of the Settings page.
public enum SettingsControl: String, CaseIterable, Sendable {
    case window, textSize, readingWidth
    case allowInput, statusLine, claudeQuestions
    case remoteAccess, connectWith, tailscaleSteps, address, devices, pictures, phoneNotifications, agentCommand
    case autoUpdate, version
}
