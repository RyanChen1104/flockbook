import SwiftUI
import AppKit

/// Assistant markdown as a blog-style article (docs/design/reading.md).
/// Parses full markdown (headings, nested/ordered/task lists, quotes, code, tables) and applies the §3 gaps.
struct MarkdownView: View {
    let text: String
    /// Older replies longer than 40 lines fold to 14 lines. The latest reply never folds.
    var foldable = false
    @AppStorage(ReadingSize.key, store: AppDefaults.store) private var sizeRaw = ReadingSize.m.rawValue
    @State private var expanded = false
    @AppStorage(ReadingWidth.key, store: AppDefaults.store) private var widthRaw = ReadingWidth.medium.rawValue   // re-renders when the width changes

    private var size: ReadingSize { ReadingSize(rawValue: sizeRaw) ?? .m }

    var body: some View {
        let (blocks, lines) = MarkdownCache.blocksAndLines(for: text, size: size)
        let fold = foldable && !expanded && lines > 40
        VStack(alignment: .leading, spacing: 0) {
            content(blocks)
                .frame(maxHeight: fold ? size.line * 14 : nil, alignment: .top)
                .clipped()
                .mask {
                    if fold {
                        VStack(spacing: 0) { Color.black; LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 48) }
                    } else { Color.black }
                }
            if foldable && lines > 40 {
                Button { withAnimation(.snappy(duration: 0.15)) { expanded.toggle() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                        Text(expanded ? "Show less" : "Show full reply · \(Self.words(text)) words")
                    }
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).frame(height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func content(_ blocks: [MBlock]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                BlockView(block: b, size: size)
                    .padding(.top, i == 0 ? 0 : Self.gap(blocks[i - 1], b, size))
            }
        }
    }

    /// Vertical gap between two neighbouring blocks (reading.md §3).
    static func gap(_ a: MBlock, _ b: MBlock, _ size: ReadingSize) -> CGFloat {
        func heavy(_ k: MBlock.Kind) -> Bool { switch k { case .code, .table, .quote: true; default: false } }
        if case .heading(let l) = b.kind { return l == 1 ? 32 : l == 2 ? 28 : 22 }
        if case .heading(let l) = a.kind { return l == 1 ? 12 : l == 2 ? 10 : 6 }
        if heavy(a.kind) || heavy(b.kind) { return 20 }
        if case .item(let d1, _, _, _) = a.kind, case .item(let d2, _, _, _) = b.kind { return d2 > d1 ? 4 : 6 }
        if case .item = a.kind { return 10 }
        if case .item = b.kind { return 10 }
        if case .rule = a.kind { return 24 }
        if case .rule = b.kind { return 24 }
        return 14
    }

    static func words(_ s: String) -> String {
        let n = s.split { $0.isWhitespace }.count
        return n.formatted()
    }
    /// Rough rendered line count, used only to decide folding.
    static func estimatedLines(_ s: String, size: ReadingSize) -> Int {
        let perLine = max(20, Int(size.column / (size.body * 0.48)))
        return s.components(separatedBy: "\n").reduce(0) { $0 + max(1, ($1.count + perLine - 1) / perLine) }
    }
}

/// Parsed blocks (and the fold line estimate) per message text, so re-rendering never re-parses or re-counts.
@MainActor enum MarkdownCache {
    private struct Entry { var blocks: [MBlock]; var lines: [ReadingSize: Int] = [:] }
    private static var store: [String: Entry] = [:]
    static func blocks(for text: String) -> [MBlock] { blocksAndLines(for: text, size: nil).blocks }
    /// One lookup for both: hashing a long reply is itself a cost on every render.
    static func blocksAndLines(for text: String, size: ReadingSize?) -> (blocks: [MBlock], lines: Int) {
        let cached = store[text]
        if let cached, let size, let n = cached.lines[size] { return (cached.blocks, n) }
        if let cached, size == nil { return (cached.blocks, 0) }
        var e = cached ?? Entry(blocks: MBlock.parse(text))
        let lines = size.map { MarkdownView.estimatedLines(text, size: $0) } ?? 0
        if let size { e.lines[size] = lines }
        if cached == nil, store.count > 400 { store.removeAll(keepingCapacity: true) }
        store[text] = e
        return (e.blocks, lines)
    }
}

struct MBlock {
    enum Kind {
        case paragraph
        case heading(Int)
        /// `task`: nil = plain item, false/true = unchecked/checked box.
        case item(depth: Int, ordered: Bool, ordinal: Int, task: Bool?)
        case quote(depth: Int)
        case code(lang: String?)
        case table(rows: [[AttributedString]], aligns: [Alignment])
        case rule
    }
    var kind: Kind
    var text: AttributedString

    static func parse(_ s: String) -> [MBlock] {
        guard let attr = try? AttributedString(markdown: s, options: .init(allowsExtendedAttributes: true, interpretedSyntax: .full,
                                                                          failurePolicy: .returnPartiallyParsedIfPossible)) else {
            return [MBlock(kind: .paragraph, text: AttributedString(s))]
        }
        var out: [MBlock] = []
        var lastID: Int?
        var tables: [Int: Int] = [:]                       // table identity -> index in `out`
        var tableCells: [Int: [Int: [Int: AttributedString]]] = [:]
        var tableAligns: [Int: [Alignment]] = [:]
        for run in attr.runs {
            guard let comps = run.presentationIntent?.components, let leaf = comps.first else {
                if out.isEmpty || lastID != nil { out.append(MBlock(kind: .paragraph, text: AttributedString())); lastID = nil }
                out[out.count - 1].text += AttributedString(attr[run.range]); continue
            }
            let slice = AttributedString(attr[run.range])
            var lists: [PresentationIntent.Kind] = [], ordinal = 1, inQuote = 0
            for c in comps {
                switch c.kind {
                case .orderedList, .unorderedList: lists.append(c.kind)
                case .listItem(let o): if lists.isEmpty { ordinal = o }
                case .blockQuote: inQuote += 1
                default: break
                }
            }
            // table cell
            if case .tableCell(let col) = leaf.kind,
               let tbl = comps.first(where: { if case .table = $0.kind { true } else { false } }) {
                var row = 0
                for c in comps { if case .tableRow(let r) = c.kind { row = r + 1 }; if case .tableHeaderRow = c.kind { row = 0 } }
                if tables[tbl.identity] == nil {
                    out.append(MBlock(kind: .rule, text: AttributedString())); tables[tbl.identity] = out.count - 1
                    if case .table(let cols) = tbl.kind {
                        tableAligns[tbl.identity] = cols.map { c in
                            switch c.alignment { case .center: .center; case .right: .trailing; default: .leading }
                        }
                    }
                }
                tableCells[tbl.identity, default: [:]][row, default: [:]][col, default: AttributedString()] += slice
                lastID = nil
                continue
            }
            let kind: Kind
            switch leaf.kind {
            case .header(let l): kind = .heading(l)
            case .codeBlock(let lang): kind = .code(lang: lang)
            case .thematicBreak: kind = .rule
            default:
                if let l = lists.first {
                    var ordered = false
                    if case .orderedList = lists.first! { ordered = true }
                    _ = l
                    kind = .item(depth: lists.count, ordered: ordered, ordinal: ordinal, task: nil)
                } else if inQuote > 0 { kind = .quote(depth: inQuote) }
                else { kind = .paragraph }
            }
            // A new leaf identity starts a new block; list items with several paragraphs keep separate blocks.
            if lastID != leaf.identity || out.isEmpty { out.append(MBlock(kind: kind, text: AttributedString())); lastID = leaf.identity }
            out[out.count - 1].text += slice
        }
        // fill tables
        for (id, idx) in tables {
            let rows = tableCells[id] ?? [:]
            let nCols = (rows.values.flatMap { $0.keys }.max() ?? -1) + 1
            let sorted = rows.keys.sorted().map { r in (0..<nCols).map { rows[r]?[$0] ?? AttributedString() } }
            out[idx].kind = .table(rows: sorted, aligns: tableAligns[id] ?? [])
        }
        // task list markers and trailing newlines
        for i in out.indices {
            if case .code = out[i].kind {
                var t = String(out[i].text.characters)
                if t.hasSuffix("\n") { t.removeLast(); out[i].text = AttributedString(t) }
            }
            if case .item(let d, let o, let n, _) = out[i].kind {
                let t = String(out[i].text.characters)
                for (p, v) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where t.hasPrefix(p) {
                    out[i].text = AttributedString(out[i].text[out[i].text.index(out[i].text.startIndex, offsetByCharacters: p.count)...])
                    out[i].kind = .item(depth: d, ordered: o, ordinal: n, task: v)
                    break
                }
            }
        }
        return out.isEmpty ? [MBlock(kind: .paragraph, text: AttributedString(s))] : out
    }
}

private struct BlockView: View {
    let block: MBlock
    let size: ReadingSize

    var body: some View {
        switch block.kind {
        case .paragraph: prose(size.body)
        case .heading(let l):
            let sz = l == 1 ? size.h1 : l == 2 ? size.h2 : l == 3 ? size.h3 : size.body - 1
            Text(styled(block.text, size: sz, weight: l == 1 ? .bold : .semibold, color: l >= 4 ? .secondary : nil))
                .lineSpacing(max(0, sz * 1.36 - sz * 1.19)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .item(let depth, let ordered, let ordinal, let task):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                // Grows with the reading size: at XL a 24 pt column is filled by the checkbox glyph itself.
                marker(depth: depth, ordered: ordered, ordinal: ordinal, task: task)
                    .frame(width: markerWidth, alignment: ordered ? .trailing : .center)
                prose(size.body, color: task == true ? .secondary : nil)
            }
            .padding(.leading, CGFloat(min(depth, 4) - 1) * markerWidth)
        case .quote(let depth):
            HStack(alignment: .top, spacing: 14) {
                ForEach(0..<depth, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.16)).frame(width: 3)
                }
                prose(size.body, color: .secondary)
            }
        case .code(let lang): CodeBlockView(text: String(block.text.characters), lang: lang, size: size)
        case .table(let rows, let aligns): TableView(rows: rows, aligns: aligns, size: size)
        case .rule:
            Rectangle().fill(ReadingColor.hairline).frame(width: 120, height: 1).frame(maxWidth: .infinity)
        }
    }

    private var markerWidth: CGFloat { max(24, size.body * 1.6) }   // S 24, M 25.6, L 28.8, XL 32

    private func prose(_ sz: CGFloat, color: Color? = nil) -> some View {
        Text(styled(block.text, size: sz, weight: .regular, color: color))
            .lineSpacing(size.lineSpacing).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func marker(depth: Int, ordered: Bool, ordinal: Int, task: Bool?) -> some View {
        if let task {
            Image(systemName: task ? "checkmark.square.fill" : "square").font(.system(size: size.body))
                .foregroundStyle(task ? Color.accentColor : Color.secondary)
        } else if ordered {
            Text("\(ordinal).").monospacedDigit().font(.system(size: size.body)).foregroundStyle(.secondary).padding(.trailing, 6)
        } else {
            Text(["•", "◦", "▪"][min(depth, 3) - 1]).font(.system(size: size.body)).foregroundStyle(.secondary)
        }
    }

    /// Applies body font, semibold bold, italic, inline code and link styling run by run.
    private func styled(_ a: AttributedString, size sz: CGFloat, weight: Font.Weight, color: Color?) -> AttributedString {
        var out = a
        for run in a.runs {
            let r = run.range
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                out[r].font = .system(size: size.inlineCode, design: .monospaced)
                out[r].backgroundColor = ReadingColor.inlineFill
            } else {
                var f = Font.system(size: sz, weight: intent.contains(.stronglyEmphasized) && weight == .regular ? .semibold : weight)
                if intent.contains(.emphasized) { f = f.italic() }
                out[r].font = f
            }
            if run.link != nil {
                out[r].foregroundColor = ReadingColor.link
                out[r].underlineStyle = .single
            } else if let color { out[r].foregroundColor = color }
            if intent.contains(.strikethrough) { out[r].strikethroughStyle = .single }
        }
        return out
    }
}

private struct CodeBlockView: View {
    let text: String
    let lang: String?
    let size: ReadingSize
    @State private var hover = false
    @State private var showAll = false

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        let fold = lines.count > 24 && !showAll
        // Estimated from the longest line (no layout measuring): wider than the column means the block scrolls.
        let wide = Double(lines.map(\.count).max() ?? 0) * size.codeBlock * 0.6 > size.column - 28
        let shown = fold ? lines.prefix(16).joined(separator: "\n") : text
        VStack(alignment: .leading, spacing: 0) {
            if lang?.isEmpty == false || hover {
                HStack {
                    Text(lang ?? "").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    if hover {
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } label: {
                            Image(systemName: "doc.on.doc").font(.callout)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy")
                    }
                }
                .frame(height: 26)
            }
            ScrollView(.horizontal) {
                Text(Highlight.attributed(shown, lang: lang)).font(.system(size: size.codeBlock, design: .monospaced)).lineSpacing(max(0, size.codeLine - size.codeBlock * 1.2))
                    .foregroundStyle(ReadingColor.codeText).fixedSize().textSelection(.enabled)
                    .padding(.trailing, wide ? 24 : 0)
            }
            .trailingFade(wide)
            .scrollIndicators(hover ? .automatic : .hidden)
            if lines.count > 24 {
                Button { withAnimation(.snappy(duration: 0.15)) { showAll.toggle() } } label: {
                    Text(showAll ? "Show less" : "Show all \(lines.count) lines")
                        .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).frame(height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReadingColor.codeFill, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(ReadingColor.hairline))
        .onHover { hover = $0 }
    }
}

/// Column widths follow the content: each column wants its longest cell on one line (capped at 300 pt); the width
/// on offer is shared in that proportion. Cells wrap, rows are as tall as their tallest cell, nothing is cut or overlaps.
private struct TableGridLayout: Layout {
    let nCols: Int
    let naturals: [CGFloat]      // wanted width per column, capped
    let minCol: CGFloat
    /// true inside a horizontal ScrollView: no width on offer, so use the natural widths.
    var scrollMode = false

    private var mins: [CGFloat] { naturals.map { min($0, minCol) } }
    private func widths(avail: CGFloat?) -> [CGFloat] {
        guard let avail else { return scrollMode ? naturals : mins }
        let total = naturals.reduce(0, +)
        guard total > 0 else { return naturals }
        if total <= avail { return naturals.map { $0 * avail / total } }   // everything fits on one line: share the room
        // Too wide: columns that would fall below their minimum keep it; the rest share what is left, in proportion.
        var w = naturals
        var pinned = Set<Int>()
        for _ in 0..<nCols {
            let free = avail - pinned.reduce(0) { $0 + mins[$1] }
            let freeTotal = naturals.enumerated().filter { !pinned.contains($0.offset) }.reduce(0) { $0 + $1.element }
            guard freeTotal > 0 else { break }
            var changed = false
            for c in 0..<nCols where !pinned.contains(c) {
                w[c] = naturals[c] * free / freeTotal
                if w[c] < mins[c] { pinned.insert(c); changed = true }
            }
            if !changed { break }
        }
        for c in pinned { w[c] = mins[c] }
        return w
    }
    private func rowHeights(_ subviews: Subviews, _ w: [CGFloat]) -> [CGFloat] {
        guard nCols > 0 else { return [] }
        return stride(from: 0, to: subviews.count, by: nCols).map { start in
            (0..<nCols).map { c in
                start + c < subviews.count ? subviews[start + c].sizeThatFits(ProposedViewSize(width: w[c], height: nil)).height : 0
            }.max() ?? 0
        }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = widths(avail: proposal.width)
        return CGSize(width: w.reduce(0, +), height: rowHeights(subviews, w).reduce(0, +))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = widths(avail: bounds.width)
        let heights = rowHeights(subviews, w)
        var y = bounds.minY
        var probeRows: [(y: CGFloat, h: CGFloat)] = []
        var fits = true
        for (r, h) in heights.enumerated() {
            var x = bounds.minX
            for c in 0..<nCols where r * nCols + c < subviews.count {
                let sv = subviews[r * nCols + c]
                if sv.sizeThatFits(ProposedViewSize(width: w[c], height: nil)).height > h + 0.5 { fits = false }
                sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: w[c], height: h))
                x += w[c]
            }
            probeRows.append((y - bounds.minY, h))
            y += h
        }
        MainActor.assumeIsolated { TableLayoutProbe.rows["\(nCols)x\(subviews.count)"] = probeRows; if !fits { TableLayoutProbe.misfit.insert("\(nCols)x\(subviews.count)") } }
    }
}

private struct TableView: View {
    let rows: [[AttributedString]]
    let aligns: [Alignment]
    let size: ReadingSize
    @State private var showAll = false

    var body: some View {
        let nCols = rows.map(\.count).max() ?? 0
        let fold = rows.count > 16 && !showAll
        let visible = fold ? Array(rows.prefix(11)) : rows
        let naturals: [CGFloat] = (0..<nCols).map { c in
            let longest = rows.map { r in c < r.count ? Self.textWidth(r[c], size.table) : 0 }.max() ?? 0
            return min(300, max(48, longest + 24))
        }
        let minCol: CGFloat = 80
        VStack(spacing: 0) {
            // Fits at minimum widths: shown at the full column width, wrapping as needed. Otherwise it scrolls sideways.
            ViewThatFits(in: .horizontal) {
                grid(visible, nCols: nCols, naturals: naturals, minCol: minCol, scroll: false)
                    .frame(maxWidth: .infinity)
                ScrollView(.horizontal) {
                    grid(visible, nCols: nCols, naturals: naturals, minCol: minCol, scroll: true).padding(.trailing, 24)
                }
                .trailingFade(true)
            }
            if rows.count > 16 {
                Divider().opacity(0.6)
                Button { withAnimation(.snappy(duration: 0.15)) { showAll.toggle() } } label: {
                    Text(showAll ? "Show fewer rows" : "Show \(rows.count - 11) more rows")
                        .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).frame(height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func grid(_ visible: [[AttributedString]], nCols: Int, naturals: [CGFloat], minCol: CGFloat, scroll: Bool) -> some View {
        TableGridLayout(nCols: nCols, naturals: naturals, minCol: minCol, scrollMode: scroll) {
            ForEach(Array(visible.enumerated()), id: \.offset) { r, row in
                ForEach(0..<nCols, id: \.self) { c in
                    cell(c < row.count ? row[c] : AttributedString(), header: r == 0, col: c)
                        .background(r == 0 ? Color.primary.opacity(0.04) : .clear)
                        .overlay(alignment: .bottom) {
                            if r < visible.count - 1 { Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 0.5) }
                        }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(Color.primary.opacity(0.14), lineWidth: 0.5))
    }

    /// One-line width estimate: CJK counts a full em, other characters about 0.56 em.
    private static func textWidth(_ a: AttributedString, _ pt: CGFloat) -> CGFloat {
        a.characters.reduce(0) { acc, ch in acc + (ch.unicodeScalars.first.map { $0.value >= 0x2E80 } == true ? pt : pt * 0.56) }
    }

    private func cell(_ a: AttributedString, header: Bool, col: Int) -> some View {
        var s = a
        for run in a.runs {
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                s[run.range].font = .system(size: size.table, design: .monospaced)
                s[run.range].backgroundColor = ReadingColor.inlineFill
            } else {
                s[run.range].font = .system(size: size.table, weight: header || intent.contains(.stronglyEmphasized) ? .semibold : .regular)
            }
            if run.link != nil { s[run.range].foregroundColor = ReadingColor.link; s[run.range].underlineStyle = .single }
        }
        let al = col < aligns.count ? aligns[col] : .leading
        return Text(s).textSelection(.enabled)
            .multilineTextAlignment(al == .trailing ? .trailing : al == .center ? .center : .leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)   // wrap, never cut: the row grows
            .padding(.vertical, 7).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: al.horizontal, vertical: .center))
    }
}

/// Test hook: row frames and fit of the last table layout.
@MainActor enum TableLayoutProbe {
    /// Keyed "columns x cells": the app window may lay out other tables meanwhile.
    nonisolated(unsafe) static var rows: [String: [(y: CGFloat, h: CGFloat)]] = [:]
    nonisolated(unsafe) static var misfit: Set<String> = []
}
