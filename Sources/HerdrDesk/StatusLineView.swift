import HerdrKit
import SwiftUI

extension AppModel {
    /// Reads a Claude pane's saved status line (the wrapper's files; read-only). Off, or none: no line.
    func checkStatusLine(for pane: Pane) {
        let r = pane.agent.flatMap { $0.kind == "claude" ? $0.sessionId : nil }
            .flatMap { StatusLineSetup.live.record(session: $0) }
            .flatMap { $0.isEmpty ? nil : $0 }
        if statusLines[pane.id] != r { statusLines[pane.id] = r }
    }
}

/// Claude Code's status row over the composer (appendix C): one tag per fact Claude Code's JSON gives (the model in
/// bold, effort, context with its bar, orange from 80%, the cost marked as an estimate), in one row; the tags that do
/// not fit are left out and a chevron at the right opens the rest. The owner's own lines are only in the open view, so
/// with them the chevron is always there. Open: every tag, wrapped; the owner's lines in their colours, each scrolling
/// sideways; when Claude Code last ran the line. Without the JSON's facts the row is the owner's first line, cut.
struct StatusLineBar: View {
    let record: StatusLineRecord
    @State private var expanded: Bool
    init(record: StatusLineRecord, expanded: Bool = false) { self.record = record; _expanded = State(initialValue: expanded) }
    @Environment(\.colorScheme) private var scheme
    @AppStorage(ReadingSize.key, store: AppDefaults.store) private var sizeRaw = ReadingSize.m.rawValue
    @AppStorage(ReadingWidth.key, store: AppDefaults.store) private var widthRaw = ReadingWidth.medium.rawValue
    private var size: ReadingSize { ReadingSize(rawValue: sizeRaw) ?? .m }
    private var tags: [StatusTag] { record.info?.tags ?? [] }

    var body: some View {
        let width = ReadingWidth(rawValue: widthRaw) ?? .medium
        ZeroWidthAs(width: size.column + 2 * width.sidePadding) {
            Group { if expanded { open } else { row } }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Claude Code status line")
                .readingColumn(size, width, alignment: .leading)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { StatusLineProbe.frame = $0 }
                // Close over the composer (its column has 6 pt over it).
                .padding(.top, 6).padding(.bottom, -2)
        }
    }

    /// One row: the tags that fit and the chevron; without facts, the owner's first line.
    @ViewBuilder private var row: some View {
        if tags.isEmpty {
            HStack(spacing: 6) {
                Text(Self.attributed(record.lines.first ?? [], dark: scheme == .dark))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                chevron
            }
            .onAppear { StatusLineProbe.plain = true; StatusLineProbe.fit = .init(shown: 0, chevron: true) }
        } else {
            StatusRowLayout(more: !record.lines.isEmpty) {
                ForEach(tags, id: \.kind) { StatusTagView(tag: $0) }
                chevron
            }
            .clipped()
        }
    }

    private var open: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                if !tags.isEmpty {
                    FlowLayout(spacing: 6) { ForEach(tags, id: \.kind) { StatusTagView(tag: $0) } }
                }
                ForEach(Array(record.lines.enumerated()), id: \.offset) { _, line in
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(Self.attributed(line, dark: scheme == .dark)).fixedSize().textSelection(.enabled)
                    }
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Text("Updated \(record.time.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            chevron
        }
    }

    private var chevron: some View {
        let label = expanded ? "Hide the whole status line" : "Show the whole status line"
        return Button { expanded.toggle() } label: {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 22, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
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

/// One fact: its text (the model in bold), the context's bar, orange when the context is nearly full.
struct StatusTagView: View {
    let tag: StatusTag
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let warn = StatusLineBar.rgb(StatusTag.warnHex(dark: dark)).map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? .orange
        let fill = StatusLineBar.rgb(StatusTag.tagHex(dark: dark)).map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? .clear
        HStack(spacing: 5) {
            Text(tag.text)
                .fontWeight(tag.kind == .model ? .bold : .regular)
                .foregroundStyle(tag.warn ? AnyShapeStyle(warn) : tag.kind == .model ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            if let p = tag.percent {
                Capsule().fill(Color.primary.opacity(0.15)).frame(width: 28, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(tag.warn ? AnyShapeStyle(warn) : AnyShapeStyle(Color.primary.opacity(0.5)))
                            .frame(width: 28 * CGFloat(min(max(p, 0), 100)) / 100)
                    }
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(fill, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tag.spoken)
        .onAppear { if tag.warn { StatusLineProbe.warn = true } }
    }
}

/// The status row: the tags in order while they fit, then the chevron at the right (`StatusTagRow.fit`). The rest go
/// out of the row (the row clips them). The last subview is the chevron.
struct StatusRowLayout: Layout {
    var spacing: CGFloat = 6
    /// Own lines that only the open view shows: the chevron stays.
    var more: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let ideal = sizes.map(\.width).reduce(0, +) + CGFloat(max(sizes.count - 1, 0)) * spacing
        let w = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal
        return CGSize(width: w, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let chevron = subviews.last else { return }
        let tags = subviews.dropLast()
        let widths = tags.map { $0.sizeThatFits(.unspecified).width }
        let f = StatusTagRow.fit(widths: widths, chevron: chevron.sizeThatFits(.unspecified).width, spacing: spacing,
                                 available: bounds.width, more: more)
        let away = CGPoint(x: bounds.maxX + 10_000, y: bounds.midY)
        var x = bounds.minX
        for (i, t) in tags.enumerated() {
            if i - tags.startIndex < f.shown {
                t.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: .unspecified)
                x += widths[i - tags.startIndex] + spacing
            } else {
                t.place(at: away, anchor: .leading, proposal: .unspecified)
            }
        }
        chevron.place(at: f.chevron ? CGPoint(x: bounds.maxX, y: bounds.midY) : away, anchor: .trailing, proposal: .unspecified)
        MainActor.assumeIsolated { StatusLineProbe.fit = f }
    }
}

extension StatusLineProbe {
    /// The bar's frame on screen (offscreen checks).
    static var frame = CGRect.zero
    /// What fit in the row; whether the owner's line stands in for the tags; whether the context tag is orange.
    static var fit: StatusTagRow.Fit?
    static var plain = false
    static var warn = false
}
