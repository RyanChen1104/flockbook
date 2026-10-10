import AppKit
import SwiftUI

/// ⌘/ keyboard shortcuts panel. The rows come from the app's real menu key equivalents at open time, plus the few keys no
/// menu owns, so the list cannot drift from the menus. The menu item calls `toggle()`; the root view carries
/// `.shortcutsPanelHost()`.
@MainActor enum ShortcutsPanel {
    @Observable final class State {
        var shown = false
        var query = ""
    }
    static let state = State()
    static let fade = Animation.easeOut(duration: 0.2)

    static func toggle() { state.shown ? close() : open() }
    static func open() { state.query = ""; withAnimation(fade) { state.shown = true } }
    static func close() { withAnimation(fade) { state.shown = false } }

    /// Local key monitor while the panel is up: Esc closes it, whatever has focus.
    static func handle(_ e: NSEvent) -> NSEvent? {
        guard state.shown, e.type == .keyDown, e.keyCode == 53 else { return e }
        close()
        return nil
    }

    /// Search field only for a long list (owner brief: more than 30 rows).
    static let searchThreshold = 30
}

struct Shortcut: Hashable {
    let title: String
    /// One entry per keycap ("⌃", "⇧", "⌘", "←"); "–" marks a range.
    let caps: [String]
    /// The caps as one string ("⌃⇧⌘←"): search and checks.
    var keys: String { caps.joined() }
}

struct ShortcutGroup: Identifiable, Hashable {
    let title: String
    var items: [Shortcut]
    var id: String { title }
}

enum ShortcutList {
    /// Keys that no menu item owns (composer, sheets, search list).
    static let other = ShortcutGroup(title: "Other Keys", items: [
        Shortcut(title: "Send message", caps: ["↩"]),
        Shortcut(title: "New line in message", caps: ["⇧", "↩"]),
        Shortcut(title: "Open selected search result", caps: ["↩"]),
        Shortcut(title: "Close sheet, terminal, or this panel", caps: ["⎋"]),
    ])

    /// One group per top-level menu, in menu order; then `other`.
    @MainActor static func groups(from menu: NSMenu?) -> [ShortcutGroup] {
        var out: [ShortcutGroup] = []
        for top in menu?.items ?? [] {
            guard let sub = top.submenu, !top.isHidden else { continue }
            let title = !sub.title.isEmpty ? sub.title : !top.title.isEmpty ? top.title : ProcessInfo.processInfo.processName
            let items = collapseTabNumbers(rows(in: sub))
            if !items.isEmpty { out.append(ShortcutGroup(title: title, items: items)) }
        }
        return out + [other]
    }

    @MainActor private static func rows(in menu: NSMenu) -> [Shortcut] {
        var out: [Shortcut] = []
        for item in menu.items where !item.isSeparatorItem && !item.isHidden && !item.isAlternate {
            if let sub = item.submenu {
                // Services act for other apps (Make New Sticky Note, Search With Google): not our shortcuts.
                if sub === NSApp.servicesMenu || item.title == "Services" { continue }
                out += rows(in: sub); continue
            }
            guard !item.keyEquivalent.isEmpty, !item.title.isEmpty else { continue }
            // The system adds Emoji & Symbols; its stored key (⌘Space) is not the key that opens it (fn E).
            if item.action == #selector(NSApplication.orderFrontCharacterPalette(_:)) { continue }
            let s = Shortcut(title: item.title, caps: glyphs(key: item.keyEquivalent, mask: item.keyEquivalentModifierMask))
            if !out.contains(s) { out.append(s) }
        }
        return out
    }

    /// "Tab 1" ⌘1 … "Tab 9" ⌘9 read as one row.
    private static func collapseTabNumbers(_ rows: [Shortcut]) -> [Shortcut] {
        let numbered = rows.filter { r in
            r.title.hasPrefix("Tab ") && Int(r.title.dropFirst(4)) != nil && r.keys == "⌘\(r.title.dropFirst(4))"
        }
        guard numbered.count > 1, let first = numbered.first, let last = numbered.last else { return rows }
        let n1 = first.title.dropFirst(4), n2 = last.title.dropFirst(4)
        let merged = Shortcut(title: "Go to Tab \(n1)–\(n2)", caps: ["⌘", String(n1), "–", String(n2)])
        var out: [Shortcut] = []
        for r in rows {
            if r == first { out.append(merged) } else if !numbered.contains(r) { out.append(r) }
        }
        return out
    }

    /// The keycaps as the system menu orders them: modifiers in ⌃⌥⇧⌘ order, then the key glyph.
    static func glyphs(key: String, mask: NSEvent.ModifierFlags) -> [String] {
        var mask = mask
        var k = key
        // An uppercase letter as the key equivalent means Shift.
        if k.count == 1, k.lowercased() != k { mask.insert(.shift) }
        k = name(of: k)
        var s: [String] = []
        if mask.contains(.function) { s.append("fn") }
        if mask.contains(.control) { s.append("⌃") }
        if mask.contains(.option) { s.append("⌥") }
        if mask.contains(.shift) { s.append("⇧") }
        if mask.contains(.command) { s.append("⌘") }
        return s + [k]
    }

    private static func name(of key: String) -> String {
        guard let u = key.unicodeScalars.first, key.unicodeScalars.count == 1 else { return key.uppercased() }
        switch Int(u.value) {
        case 0x0D: return "↩"
        case 0x03: return "⌤"
        case 0x09, 0x19: return "⇥"
        case 0x1B: return "⎋"
        case 0x08, 0x7F: return "⌫"
        case 0x20: return "Space"
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case NSDeleteFunctionKey: return "⌦"
        case NSHomeFunctionKey: return "↖"
        case NSEndFunctionKey: return "↘"
        case NSPageUpFunctionKey: return "⇞"
        case NSPageDownFunctionKey: return "⇟"
        case NSF1FunctionKey...NSF35FunctionKey: return "F\(Int(u.value) - NSF1FunctionKey + 1)"
        default: return key.uppercased()
        }
    }

    /// Rows whose title or group contains `query` (case-insensitive); all rows for an empty query.
    static func filter(_ groups: [ShortcutGroup], _ query: String) -> [ShortcutGroup] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return groups }
        return groups.compactMap { g in
            if g.title.localizedCaseInsensitiveContains(q) { return g }
            let hits = g.items.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.keys.contains(q) }
            return hits.isEmpty ? nil : ShortcutGroup(title: g.title, items: hits)
        }
    }

    /// Groups into `n` columns in order, each group to the shortest column so far (by rows + a header).
    static func columns(_ groups: [ShortcutGroup], _ n: Int) -> [[ShortcutGroup]] {
        var cols = Array(repeating: [ShortcutGroup](), count: n), heights = Array(repeating: 0, count: n)
        for g in groups {
            let i = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            cols[i].append(g); heights[i] += g.items.count + 2
        }
        return cols
    }
}

extension View {
    /// Draws the shortcuts panel over this view while `ShortcutsPanel.state.shown`. `report` gets the panel frame in this
    /// view's window (tests: each host reports its own panel; the app's window may show one too).
    func shortcutsPanelHost(report: ((CGRect) -> Void)? = nil) -> some View { modifier(ShortcutsPanelHost(report: report)) }
}

struct ShortcutsPanelHost: ViewModifier {
    var report: ((CGRect) -> Void)?
    /// Window height: the panel is never taller than the window (the list scrolls instead).
    @State private var room: CGFloat = 0
    func body(content: Content) -> some View {
        content
        // Measured on the content, not inside the overlay: the panel's own size must not feed back into it.
        .onGeometryChange(for: CGFloat.self) { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom } action: { room = $0 }
        .overlay {
            if ShortcutsPanel.state.shown {
                ZStack {
                    // Click outside closes; VoiceOver gets it as a button.
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { ShortcutsPanel.close() }
                        .accessibilityElement()
                        .accessibilityLabel("Close Keyboard Shortcuts")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { ShortcutsPanel.close() }
                    ShortcutsPanelView(maxHeight: room > 0 ? room - 64 : 620)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { report?($0) }
                }
                .ignoresSafeArea()   // centred on the whole window, not the area under the toolbar
                .transition(.opacity)
            }
        }
    }
}

struct ShortcutsPanelView: View {
    /// The window height less a margin: the panel shows every row when it fits and scrolls otherwise.
    var maxHeight: CGFloat = 620
    @State private var groups: [ShortcutGroup] = []
    @State private var monitor: Any?
    /// Height of the full list: the panel keeps it while a search filters rows, so it does not jump.
    @State private var fullHeight: CGFloat = 0
    private var state: ShortcutsPanel.State { ShortcutsPanel.state }

    var body: some View {
        let rowCount = groups.reduce(0) { $0 + $1.items.count }
        let shown = ShortcutList.filter(groups, state.query)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("Keyboard Shortcuts").font(.title3.weight(.semibold))
                Spacer()
                if rowCount > ShortcutsPanel.searchThreshold {
                    ShortcutSearchField(text: Binding(get: { state.query }, set: { state.query = $0 }))
                        .frame(width: 200)
                }
            }
            OptionalScroll {
                if shown.isEmpty {
                    Text("No shortcut matches “\(state.query)”.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
                } else {
                    HStack(alignment: .top, spacing: 28) {
                        ForEach(Array(ShortcutList.columns(shown, 2).enumerated()), id: \.offset) { _, col in
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(col) { group($0) }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 680)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if state.query.isEmpty { fullHeight = $0 } }
        .frame(minHeight: state.query.isEmpty ? nil : fullHeight, alignment: .top)
        .glassCard(radius: Radius.card)
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard Shortcuts")
        .onAppear {
            groups = ShortcutList.groups(from: NSApp.mainMenu)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ShortcutsPanel.handle($0) }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    private func group(_ g: ShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(g.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(g.items, id: \.self) { s in
                HStack(spacing: 12) {
                    Text(s.title).lineLimit(1)
                    Spacer(minLength: 8)
                    KbdGroup(caps: s.caps)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The system rounded search field (its focus ring follows the capsule), focused when the panel opens.
struct ShortcutSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = "Search"
        f.sendsSearchStringImmediately = true
        f.delegate = context.coordinator
        DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        return f
    }
    func updateNSView(_ f: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ShortcutSearchField
        init(_ p: ShortcutSearchField) { parent = p }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSSearchField { parent.text = f.stringValue }
        }
    }
}
