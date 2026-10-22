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

/// Claude Code's status row over the composer (appendices C and D): one tag per fact Claude Code's JSON gives (the
/// model in bold, effort, context with its bar, orange from 80%, the cost marked as an estimate), then one tag per part
/// of the owner's own line in its colours, without the parts that repeat the facts. One row: the tags that do not fit
/// are left out and a chevron at the right opens them. Open: every tag, wrapped, and when Claude Code last ran the line.
struct StatusLineBar: View {
    let record: StatusLineRecord
    @State private var expanded: Bool
    init(record: StatusLineRecord, expanded: Bool = false) { self.record = record; _expanded = State(initialValue: expanded) }
    @AppStorage(ReadingSize.key, store: AppDefaults.store) private var sizeRaw = ReadingSize.m.rawValue
    @AppStorage(ReadingWidth.key, store: AppDefaults.store) private var widthRaw = ReadingWidth.medium.rawValue
    private var size: ReadingSize { ReadingSize(rawValue: sizeRaw) ?? .m }
    private var tags: [StatusTag] { record.tags }

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

    /// One row: the tags that fit and the chevron when one is left out.
    private var row: some View {
        StatusRowLayout(more: false) {
            ForEach(Array(tags.enumerated()), id: \.offset) { StatusTagView(tag: $0.element) }
            chevron
        }
        .clipped()
    }

    private var open: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout(spacing: 6) { ForEach(Array(tags.enumerated()), id: \.offset) { StatusTagView(tag: $0.element) } }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { StatusLineProbe.openFlow = $0 }
                Text("Updated \(record.time.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { StatusLineProbe.openColumn = $0 }
            .onAppear { StatusLineProbe.openTags = tags.count }
            chevron
        }
    }

    private var chevron: some View {
        let label = expanded ? "Hide the whole status line" : "Show the whole status line"
        return Button { expanded.toggle() } label: {
            Image(systemName: StatusTagRow.chevronSymbol(open: expanded))
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 22, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
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
            if tag.kind == .own {
                Text(Self.parts(tag.runs, dark: dark)).foregroundStyle(.secondary)
            } else {
                Text(tag.text)
                    .fontWeight(tag.kind == .model ? .bold : .regular)
                    .foregroundStyle(tag.warn ? AnyShapeStyle(warn) : tag.kind == .model ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
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
        .truncationMode(.tail)
        .background(fill, in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tag.spoken)
        .onAppear { if tag.warn { StatusLineProbe.warn = true } }
    }

    /// An owner's part in its colours where they read on the tag, dim text in a fixed grey (`StatusTag.runHex`); else
    /// the tag's text colour.
    static func parts(_ runs: [StyledRun], dark: Bool) -> AttributedString {
        var out = AttributedString()
        for r in runs {
            var a = AttributedString(r.text)
            if let hex = StatusTag.runHex(r, dark: dark), let c = StatusLineBar.rgb(hex) {
                a.foregroundColor = Color(red: c.r, green: c.g, blue: c.b)
            }
            var intent: InlinePresentationIntent = []
            if r.bold { intent.insert(.stronglyEmphasized) }
            if r.italic { intent.insert(.emphasized) }
            if !intent.isEmpty { a.inlinePresentationIntent = intent }
            if r.underline { a.underlineStyle = .single }
            out += a
        }
        return out
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
    /// How many tags the open view drew.
    static var openTags: Int?
    /// The open view's tags and their column, wide (a long part must not run past the column).
    static var openFlow: CGFloat = 0
    static var openColumn: CGFloat = 0
}
