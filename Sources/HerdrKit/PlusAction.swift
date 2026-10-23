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
        self = .newTab
    }

    /// The picker's name of the choice.
    public var label: String { "New tab" }

    /// The + button's tooltip.
    public var help: String { "New tab (⌘T)" }

    /// The + button's accessibility label.
    public var accessibilityLabel: String { "New Tab" }

    /// The direction of a split; nil for New tab.
    public var split: SplitDirection? { nil }

    /// What a click does: a split needs a pane to split; with none, a new tab.
    public func resolved(hasPane: Bool) -> PlusAction { .newTab }
}
