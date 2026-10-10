import SwiftUI

/// One key as a small keycap: subtle fill, hairline edge, secondary text. Modifier and special keys draw as SF Symbols, so
/// ⌃ reads as Control and not as a caret. Used by the shortcuts panel and the question card's number hints.
struct Kbd: View {
    let key: String

    var body: some View {
        content
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, Self.symbols[key] == nil ? 5 : 3)   // symbols are wider than letters: caps stay one width
            .frame(minWidth: 20, minHeight: 20)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.key))
            .overlay(RoundedRectangle(cornerRadius: Radius.key).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
            .accessibilityElement().accessibilityLabel(Self.spoken[key] ?? key)
    }

    @ViewBuilder private var content: some View {
        if key == "⎋" {
            Text("esc")   // the ⎋ symbol reads as a refresh arrow; menus and keyboards say "esc"
        } else if let symbol = Self.symbols[key] {
            // ⌃ is a bare chevron: at the small scale of the other modifiers it reads as a caret (^).
            Image(systemName: symbol).imageScale(key == "⌃" ? .large : .small).fontWeight(.semibold)
        } else {
            Text(key)
        }
    }

    static let symbols: [String: String] = [
        "⌘": "command", "⌥": "option", "⇧": "shift", "⌃": "control",
        "↩": "return", "⌫": "delete.left", "⌦": "delete.right", "⇥": "arrow.right.to.line",
        "←": "arrow.left", "→": "arrow.right", "↑": "arrow.up", "↓": "arrow.down",
    ]
    static let spoken: [String: String] = [
        "⌘": "Command", "⌥": "Option", "⇧": "Shift", "⌃": "Control", "↩": "Return", "⎋": "Escape", "⌫": "Delete",
        "⌦": "Forward Delete", "⇥": "Tab", "`": "Backtick", "←": "Left Arrow", "→": "Right Arrow", "↑": "Up Arrow", "↓": "Down Arrow",
    ]
}

/// Keycaps in a row, 4 pt apart. "–" between caps is a range ("⌘ 1 – 9") and draws as plain text.
struct KbdGroup: View {
    let caps: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, c in
                if c == "–" { Text("–").font(.caption).foregroundStyle(.tertiary) } else { Kbd(key: c) }
            }
        }
        .fixedSize()
    }
}
