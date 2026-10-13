import SwiftUI

private struct SelectableTextKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    /// Whether conversation text can be selected here. SwiftUI puts an AppKit overlay on each selectable Text and re-sets
    /// its font on every update, which asks for another layout; with every row of a long conversation selectable, the
    /// window could lay out forever (100% CPU). The conversation turns it on only for the row under the pointer.
    var selectableText: Bool { get { self[SelectableTextKey.self] } set { self[SelectableTextKey.self] = newValue } }
}

/// `.textSelection(.enabled)` where `selectableText` is on; plain text elsewhere.
struct SelectableText: ViewModifier {
    @Environment(\.selectableText) private var on
    func body(content: Content) -> some View {
        if on { content.textSelection(.enabled) } else { content }
    }
}

extension View {
    func selectableText() -> some View { modifier(SelectableText()) }
}
