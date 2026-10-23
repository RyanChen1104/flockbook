import Foundation

/// What the toolbar's + does (Settings > General): open a new tab (the default), or split the focused pane right or
/// down. ⌘T, the menu's New Tab and the sidebar's New tab row always open a tab.
public enum PlusAction: String, CaseIterable, Identifiable, Sendable {
    case newTab, splitRight, splitDown

    /// The defaults key of the choice.
    public static let key = "plusAction"

    public var id: String { rawValue }

    /// The stored choice; nothing stored or an unknown value: New tab.
    public init(stored: String?) {
        self = stored.flatMap(PlusAction.init(rawValue:)) ?? .newTab
    }

    /// The picker's name of the choice.
    public var label: String {
        switch self {
        case .newTab: "New tab"
        case .splitRight: "Split right"
        case .splitDown: "Split down"
        }
    }

    /// The + button's tooltip.
    public var help: String { self == .newTab ? "New tab (⌘T)" : label }

    /// The + button's accessibility label.
    public var accessibilityLabel: String {
        switch self {
        case .newTab: "New Tab"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        }
    }

    /// The direction of a split; nil for New tab.
    public var split: SplitDirection? {
        switch self {
        case .newTab: nil
        case .splitRight: .right
        case .splitDown: .down
        }
    }

    /// What a click does: a split needs a pane to split; with none, a new tab.
    public func resolved(hasPane: Bool) -> PlusAction { split == nil || hasPane ? self : .newTab }
}
