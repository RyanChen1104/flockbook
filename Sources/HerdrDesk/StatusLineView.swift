import HerdrKit
import SwiftUI

extension AppModel {
    /// Reads a Claude pane's saved status line (the wrapper's files; read-only). Off, or none: no line.
    func checkStatusLine(for pane: Pane) {
        let r = pane.agent.flatMap { $0.kind == "claude" ? $0.sessionId : nil }
            .flatMap { StatusLineSetup.live.record(session: $0) }
            .flatMap { $0.shown.isEmpty ? nil : $0 }
        if statusLines[pane.id] != r { statusLines[pane.id] = r }
    }
}

/// Claude Code's status line under the composer: one small, dim, monospaced line in its own colours. A long line is
/// cut; a click shows every line, wrapped, and Claude Code's facts (its cost is an estimate). The pointer over it shows
/// the facts too.
struct StatusLineBar: View {
    let record: StatusLineRecord
    @State private var expanded: Bool
    init(record: StatusLineRecord, expanded: Bool = false) { self.record = record; _expanded = State(initialValue: expanded) }
    @Environment(\.colorScheme) private var scheme
    @AppStorage(ReadingSize.key, store: AppDefaults.store) private var sizeRaw = ReadingSize.m.rawValue
    @AppStorage(ReadingWidth.key, store: AppDefaults.store) private var widthRaw = ReadingWidth.medium.rawValue
    private var size: ReadingSize { ReadingSize(rawValue: sizeRaw) ?? .m }

    var body: some View {
        let width = ReadingWidth(rawValue: widthRaw) ?? .medium
        ZeroWidthAs(width: size.column + 2 * width.sidePadding) {
            Button { expanded.toggle() } label: { content }
                .buttonStyle(.plain)
                .help(Self.facts(record.info) ?? "")
                .accessibilityLabel("Claude Code status line")
                .accessibilityValue(ANSIText.plain(record.shown))
                .accessibilityHint(expanded ? "Shows one line" : "Shows every line")
                .readingColumn(size, width, alignment: .leading)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { StatusLineProbe.frame = $0 }
                // Close under the composer (its column has 12 pt under it).
                .padding(.top, -10).padding(.bottom, 10)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            if expanded {
                ForEach(Array(record.shown.enumerated()), id: \.offset) { _, line in
                    Text(Self.attributed(line, dark: scheme == .dark)).fixedSize(horizontal: false, vertical: true)
                }
                if let f = Self.facts(record.info) {
                    Text(f).foregroundStyle(.tertiary).padding(.top, 2)
                }
            } else {
                Text(Self.attributed(record.shown.first ?? [], dark: scheme == .dark))
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .opacity(0.85)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// "Opus 5.5 · context 37% of 1M · session $0.42 (estimate)": what Claude Code's JSON says; nil when nothing.
    static func facts(_ i: ClaudeStatusInfo?) -> String? {
        guard let i else { return nil }
        var parts: [String] = []
        if let m = i.model { parts.append(m) }
        if let p = i.contextPercent {
            parts.append("context \(p)%" + (i.contextSize.map { " of " + Self.tokens($0) } ?? ""))
        }
        if let c = i.costUSD { parts.append(String(format: "session $%.2f (estimate)", c)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 && n % 1_000_000 == 0 ? "\(n / 1_000_000)M" : n >= 1000 ? "\(n / 1000)K" : "\(n)"
    }

    static func attributed(_ line: [StyledRun], dark: Bool) -> AttributedString {
        var out = AttributedString()
        for r in line {
            var a = AttributedString(r.text)
            if let c = color(r.fg, dark: dark) { a.foregroundColor = r.dim ? c.opacity(0.6) : c }
            else if r.dim { a.foregroundColor = Color(nsColor: .tertiaryLabelColor) }
            if let b = r.bg.flatMap(rgb) { a.backgroundColor = Color(red: b.r, green: b.g, blue: b.b).opacity(0.85) }
            var intent: InlinePresentationIntent = []
            if r.bold { intent.insert(.stronglyEmphasized) }
            if r.italic { intent.insert(.emphasized) }
            if !intent.isEmpty { a.inlinePresentationIntent = intent }
            if r.underline { a.underlineStyle = .single }
            out += a
        }
        return out
    }

    /// The run's colour, unless it would vanish on this background (white on light, black on dark): then the line's own.
    static func color(_ hex: String?, dark: Bool) -> Color? {
        guard let c = hex.flatMap(rgb) else { return nil }
        let l = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        if dark ? l < 0.12 : l > 0.85 { return nil }
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        guard hex.count == 7, hex.first == "#", let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double(v >> 16 & 0xff) / 255, Double(v >> 8 & 0xff) / 255, Double(v & 0xff) / 255)
    }
}

extension StatusLineProbe {
    /// The bar's frame on screen (offscreen checks).
    static var frame = CGRect.zero
}
