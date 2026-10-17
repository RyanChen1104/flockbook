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

    /// Body evaluations so far (the bench counts how many rows a change renders again).
    static var bodies = 0
    var body: some View {
        let _ = Self.bodies += 1
        let lines = MarkdownCache.blocksAndLines(for: text, size: size).lines
        let fold = foldable && !expanded && lines > 40
        VStack(alignment: .leading, spacing: 0) {
            MessageText(content: .markdown(text, size: size), maxHeight: fold ? size.line * 14 : nil)
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
    /// Main-thread time spent parsing markdown (the bench splits a stall by it).
    static var parseTime = Duration.zero
    static func blocks(for text: String) -> [MBlock] { blocksAndLines(for: text, size: nil).blocks }
    /// One lookup for both: hashing a long reply is itself a cost on every render.
    static func blocksAndLines(for text: String, size: ReadingSize?) -> (blocks: [MBlock], lines: Int) {
        let cached = store[text]
        if let cached, let size, let n = cached.lines[size] { return (cached.blocks, n) }
        if let cached, size == nil { return (cached.blocks, 0) }
        let t = ContinuousClock.now
        var e = cached ?? Entry(blocks: MBlock.parse(text))
        if cached == nil { parseTime += ContinuousClock.now - t }
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

/// A message's text for `MessageTextView` (TextKit 1), with the reading metrics of `size` (reading.md §2–§10).
/// Gaps between blocks are paragraph spacing or block margins; code, quotes, rules and tables are text blocks.
@MainActor struct MessageBuilder {
    typealias Attrs = [NSAttributedString.Key: Any]
    let size: ReadingSize

    func markdown(_ blocks: [MBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, b) in blocks.enumerated() {
            let piece = block(b, gap: i == 0 ? 0 : MarkdownView.gap(blocks[i - 1], b, size))
            out.append(piece)
            // The break ends the piece's last paragraph, so it takes that paragraph's style.
            if i < blocks.count - 1, piece.length > 0 {
                let last = piece.attributes(at: piece.length - 1, effectiveRange: nil).filter { [.font, .paragraphStyle, .foregroundColor].contains($0.key) }
                out.append(NSAttributedString(string: "\n", attributes: last))
            }
        }
        return out
    }

    func bubble(_ text: String) -> NSAttributedString {
        let a = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return inline(a, size: size.body, para: para(spacing: max(0, size.line - 2 - size.body * 1.19)))
    }

    private func block(_ b: MBlock, gap: CGFloat) -> NSAttributedString {
        switch b.kind {
        case .paragraph:
            return inline(b.text, size: size.body, para: para(spacing: size.lineSpacing, before: gap))
        case .heading(let l):
            let sz = l == 1 ? size.h1 : l == 2 ? size.h2 : l == 3 ? size.h3 : size.body - 1
            return inline(b.text, size: sz, weight: l == 1 ? .bold : .semibold, color: l >= 4 ? .secondaryLabelColor : .labelColor,
                          para: para(spacing: max(0, sz * 1.36 - sz * 1.19), before: gap))
        case .item(let depth, let ordered, let ordinal, let task):
            return item(b.text, depth: depth, ordered: ordered, ordinal: ordinal, task: task, gap: gap)
        case .quote(let depth):
            let bars = (0..<max(1, depth)).map { _ in fullWidth(QuoteTextBlock()) }
            for q in bars { q.setWidth(17, type: .absoluteValueType, for: .padding, edge: .minX) }   // 3 pt bar, 14 pt space
            bars[0].setWidth(gap, type: .absoluteValueType, for: .margin, edge: .minY)
            return inline(b.text, size: size.body, color: .secondaryLabelColor, para: para(spacing: size.lineSpacing, blocks: bars))
        case .code(let lang):
            return code(String(b.text.characters), lang: lang, gap: gap)
        case .table(let rows, let aligns):
            return table(rows, aligns: aligns, gap: gap)
        case .rule:
            let rule = fullWidth(RuleTextBlock())
            rule.setWidth(gap, type: .absoluteValueType, for: .margin, edge: .minY)
            let p = para(spacing: 0, blocks: [rule])
            p.minimumLineHeight = 1; p.maximumLineHeight = 1
            return NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 1), .paragraphStyle: p, .messageCopy: "---"])
        }
    }

    /// Marker, then the text hanging at the marker column (reading.md §5). Markers copy as markdown ("- ", "1. ", "- [ ] ").
    private func item(_ text: AttributedString, depth: Int, ordered: Bool, ordinal: Int, task: Bool?, gap: CGFloat) -> NSAttributedString {
        let mw = max(24, size.body * 1.6)   // S 24, M 25.6, L 28.8, XL 32
        let base = CGFloat(min(depth, 4) - 1) * mw
        let p = para(spacing: size.lineSpacing, before: gap)
        p.firstLineHeadIndent = base
        p.headIndent = base + mw
        p.tabStops = [ordered && task == nil ? NSTextTab(textAlignment: .right, location: base + mw - 6) : NSTextTab(textAlignment: .center, location: base + mw / 2),
                      NSTextTab(textAlignment: .left, location: base + mw)]
        let copy = String(repeating: "  ", count: max(0, depth - 1)) + (task.map { $0 ? "- [x] " : "- [ ] " } ?? (ordered ? "\(ordinal). " : "- "))
        let markerAttrs: Attrs = [.font: NSFont.systemFont(ofSize: size.body), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p]
        let out = NSMutableAttributedString(string: "\t", attributes: markerAttrs)
        if let task, let image = NSImage(systemSymbolName: task ? "checkmark.square.fill" : "square", accessibilityDescription: task ? "Done" : "Not done")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size.body, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: task ? [.white, .controlAccentColor] : [.secondaryLabelColor]))) {
            let att = NSTextAttachment()
            att.image = image
            att.bounds = NSRect(x: 0, y: NSFont.systemFont(ofSize: size.body).descender + 1, width: image.size.width, height: image.size.height)
            out.append(NSAttributedString(attachment: att))
            out.addAttributes(markerAttrs, range: NSRange(location: 1, length: 1))
        } else {
            out.append(NSAttributedString(string: ordered ? "\(ordinal)." : ["•", "◦", "▪"][min(depth, 3) - 1],
                                          attributes: markerAttrs.merging([.font: ordered ? NSFont.monospacedDigitSystemFont(ofSize: size.body, weight: .regular)
                                                                                          : NSFont.systemFont(ofSize: size.body)]) { $1 }))
        }
        out.append(NSAttributedString(string: "\t", attributes: markerAttrs))
        out.addAttribute(.messageCopy, value: copy, range: NSRange(location: 0, length: out.length))
        out.append(inline(text, size: size.body, color: task == true ? .secondaryLabelColor : .labelColor, para: p))
        return out
    }

    /// Rounded fill, optional language label (left out of copies), highlighted code. Long lines wrap.
    private func code(_ text: String, lang: String?, gap: CGFloat) -> NSAttributedString {
        let box = fullWidth(CodeTextBlock())
        box.code = text
        for e in [NSRectEdge.minX, .maxX] { box.setWidth(14, type: .absoluteValueType, for: .padding, edge: e) }
        for e in [NSRectEdge.minY, .maxY] { box.setWidth(12, type: .absoluteValueType, for: .padding, edge: e) }
        box.setWidth(gap, type: .absoluteValueType, for: .margin, edge: .minY)
        // One paragraph style for the whole block: TextKit 1 drops the block's padding where the paragraphs in it differ.
        let p = para(spacing: max(0, size.codeLine - size.codeBlock * 1.2), blocks: [box])
        let out = NSMutableAttributedString()
        if let lang, !lang.isEmpty {
            out.append(NSAttributedString(string: lang + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p, .messageCopy: ""]))
        }
        out.append(Highlight.attributed(text.isEmpty ? " " : text, lang: lang, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size.codeBlock, weight: .regular), .foregroundColor: ReadingColor.NS.codeText, .paragraphStyle: p]))
        return out
    }

    /// Columns follow their content and share the column width; cells wrap; rows are as tall as their tallest cell.
    /// Cells copy tab-separated, one row per line.
    private func table(_ rows: [[AttributedString]], aligns: [Alignment], gap: CGFloat) -> NSAttributedString {
        let nCols = max(1, rows.map(\.count).max() ?? 1)
        let t = RoundedTextTable()
        t.numberOfColumns = nCols
        t.layoutAlgorithm = .automaticLayoutAlgorithm
        t.collapsesBorders = true
        t.setContentWidth(100, type: .percentageValueType)
        t.setWidth(gap, type: .absoluteValueType, for: .margin, edge: .minY)
        let out = NSMutableAttributedString()
        for (r, row) in rows.enumerated() {
            for c in 0..<nCols {
                let cell = NSTextTableBlock(table: t, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                for e in [NSRectEdge.minY, .maxY] { cell.setWidth(7, type: .absoluteValueType, for: .padding, edge: e) }
                for e in [NSRectEdge.minX, .maxX] { cell.setWidth(12, type: .absoluteValueType, for: .padding, edge: e) }
                cell.verticalAlignment = .middleAlignment
                if r == 0 { cell.backgroundColor = ReadingColor.NS.primary(0.04) }
                if r < rows.count - 1 {
                    cell.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .maxY)
                    cell.setBorderColor(ReadingColor.NS.primary(0.09), for: .maxY)
                }
                let p = para(spacing: 0, blocks: [cell])
                let al = c < aligns.count ? aligns[c] : .leading
                p.alignment = al == .trailing ? .right : al == .center ? .center : .left
                let text = c < row.count ? row[c] : AttributedString()
                let s = inline(text.characters.isEmpty ? AttributedString(" ") : text, size: size.table, weight: r == 0 ? .semibold : .regular,
                               mono: size.table, para: p)
                out.append(s)
                let last = r == rows.count - 1 && c == nCols - 1
                if !last {
                    var a: Attrs = [.font: NSFont.systemFont(ofSize: size.table), .paragraphStyle: p]
                    if c < nCols - 1 { a[.messageCopy] = "\t" }
                    out.append(NSAttributedString(string: "\n", attributes: a))
                }
            }
        }
        return out
    }

    /// A text block without a content width is left out of the layout (no padding, no background).
    private func fullWidth<B: NSTextBlock>(_ b: B) -> B {
        b.setContentWidth(100, type: .percentageValueType)
        return b
    }

    private func para(spacing: CGFloat, before: CGFloat = 0, blocks: [NSTextBlock] = []) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = spacing
        p.paragraphSpacingBefore = before
        p.textBlocks = blocks
        return p
    }

    /// Body font, semibold for strong, italic, inline code (monospaced on a light fill), links, strikethrough, run by run.
    private func inline(_ a: AttributedString, size sz: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
                        mono: CGFloat? = nil, para: NSParagraphStyle) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for run in a.runs {
            let intent = run.inlinePresentationIntent ?? []
            var attrs: Attrs = [.paragraphStyle: para, .foregroundColor: color]
            if intent.contains(.code) {
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: mono ?? size.inlineCode, weight: .regular)
                attrs[.backgroundColor] = ReadingColor.NS.inlineFill
            } else {
                var f = NSFont.systemFont(ofSize: sz, weight: intent.contains(.stronglyEmphasized) && weight == .regular ? .semibold : weight)
                if intent.contains(.emphasized) { f = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(.italic), size: sz) ?? f }
                attrs[.font] = f
            }
            if let url = run.link { attrs[.link] = url }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: String(a[run.range].characters), attributes: attrs))
        }
        if out.length == 0 { out.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: sz), .paragraphStyle: para])) }
        return out
    }
}

/// Test hook: row frames of each laid-out table, and tables where a cell does not hold its text.
@MainActor enum TableLayoutProbe {
    /// Keyed "columns x cells": the app window may lay out other tables meanwhile.
    nonisolated(unsafe) static var rows: [String: [(y: CGFloat, h: CGFloat)]] = [:]
    nonisolated(unsafe) static var misfit: Set<String> = []
}
