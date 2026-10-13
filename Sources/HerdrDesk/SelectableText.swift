import AppKit
import SwiftUI

/// One conversation message as one selectable text view: a drag selects across paragraphs, lists, code and tables;
/// Cmd-C and the context menu copy plain text.
///
/// SwiftUI's `.textSelection(.enabled)` puts an AppKit overlay on each Text and re-sets its font on every update, which asks
/// for another layout; a long conversation could lay out forever (100% CPU). Here the text is built once per (text, size)
/// and kept in `MessageContent`; the height is measured once per width; `updateNSView` replaces the text only when the
/// content changed.
struct MessageText: NSViewRepresentable {
    let content: MessageContent
    /// As wide as the text (a bubble); otherwise as wide as offered.
    var fit = false
    /// Folded: this tall at most, the bottom 48 pt fading out.
    var maxHeight: CGFloat? = nil

    func makeNSView(context: Context) -> MessageTextView {
        let tv = MessageTextView.make()
        tv.load(content)
        tv.fold = maxHeight
        return tv
    }

    func updateNSView(_ tv: MessageTextView, context: Context) {
        if tv.contentID != content.id { tv.load(content) }
        if tv.fold != maxHeight { tv.fold = maxHeight }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageTextView, context: Context) -> CGSize? {
        let offered = proposal.width ?? .infinity
        let width = offered.isFinite ? max(1, offered) : 100_000
        var s = content.size(width: width, fit: fit || !offered.isFinite)
        if let maxHeight { s.height = min(s.height, maxHeight) }
        return s
    }
}

/// A message's text, built once per (kind, text, size) and shared by every view that shows it.
@MainActor final class MessageContent {
    let id: Int
    let text: NSAttributedString
    private var sizes: [Int: CGSize] = [:]

    private init(_ text: NSAttributedString) {
        Self.next += 1
        id = Self.next
        self.text = text
    }

    private static var next = 0
    private enum Kind: Hashable { case markdown, bubble, plain(mono: CGFloat, error: Bool) }
    private struct Key: Hashable { let kind: Kind; let size: ReadingSize; let text: String }
    private static var store: [Key: MessageContent] = [:]

    private static func cached(_ key: Key, _ build: () -> NSAttributedString) -> MessageContent {
        if let c = store[key] { return c }
        if store.count > 400 { store.removeAll(keepingCapacity: true) }
        let c = MessageContent(build())
        store[key] = c
        return c
    }

    /// Assistant markdown (reading.md): headings, lists, quotes, code blocks, tables.
    static func markdown(_ text: String, size: ReadingSize) -> MessageContent {
        cached(Key(kind: .markdown, size: size, text: text)) { MessageBuilder(size: size).markdown(MarkdownCache.blocks(for: text)) }
    }

    /// A user bubble: inline markdown only.
    static func bubble(_ text: String, size: ReadingSize) -> MessageContent {
        cached(Key(kind: .bubble, size: size, text: text)) { MessageBuilder(size: size).bubble(text) }
    }

    /// Monospaced plain text (tool input and output, a command).
    static func plain(_ text: String, monoSize: CGFloat, error: Bool = false) -> MessageContent {
        cached(Key(kind: .plain(mono: monoSize, error: error), size: .m, text: text)) {
            NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: monoSize, weight: .regular),
                                                           .foregroundColor: error ? NSColor.systemRed : NSColor.labelColor])
        }
    }

    /// The laid-out size at `width`, measured once per width.
    func size(width: CGFloat, fit: Bool) -> CGSize {
        let key = Int((width * 2).rounded()) * 2 + (fit ? 1 : 0)
        if let s = sizes[key] { return s }
        let s = TextMeasure.size(self, width: width, fit: fit)
        if sizes.count > 16 { sizes.removeAll() }
        sizes[key] = s
        return s
    }
}

/// Lays text out away from the screen, for heights. One shared TextKit 1 stack: tables need `NSTextTable`.
@MainActor private enum TextMeasure {
    static let storage = NSTextStorage()
    static let layout = NSLayoutManager()
    static let container: NSTextContainer = {
        let c = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        c.lineFragmentPadding = 0
        layout.addTextContainer(c)
        storage.addLayoutManager(layout)
        return c
    }()

    static func size(_ content: MessageContent, width: CGFloat, fit: Bool) -> CGSize {
        let c = container
        c.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        storage.setAttributedString(content.text)
        layout.ensureLayout(for: c)
        let used = layout.usedRect(for: c)
        probeTables(width: width)
        storage.setAttributedString(NSAttributedString())   // do not keep the last message alive
        return CGSize(width: fit ? min(width, ceil(used.width)) : width, height: ceil(used.height))
    }

    /// Fills `TableLayoutProbe`: each table's row frames, and whether every cell holds its text.
    private static func probeTables(width: CGFloat) {
        var rows: [ObjectIdentifier: (table: NSTextTable, cells: Int, rows: [Int: (y: CGFloat, maxY: CGFloat)], misfit: Bool)] = [:]
        let s = storage.string as NSString
        var i = 0
        while i < s.length {
            let para = s.paragraphRange(for: NSRange(location: i, length: 0))
            i = NSMaxRange(para)
            guard let style = storage.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle,
                  let cell = style.textBlocks.last as? NSTextTableBlock else { continue }
            let glyphs = layout.glyphRange(forCharacterRange: para, actualCharacterRange: nil)
            let box = layout.boundsRect(for: cell, glyphRange: glyphs)
            let text = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let id = ObjectIdentifier(cell.table)
            var e = rows[id] ?? (cell.table, 0, [:], false)
            e.cells += 1
            let r = e.rows[cell.startingRow] ?? (box.minY, box.maxY)
            e.rows[cell.startingRow] = (min(r.y, box.minY), max(r.maxY, box.maxY))
            if text.maxY > box.maxY + 0.5 { e.misfit = true }
            rows[id] = e
        }
        for e in rows.values {
            let key = "\(e.table.numberOfColumns)x\(e.cells)"
            let sorted = e.rows.keys.sorted().compactMap { e.rows[$0] }
            let top = sorted.first?.y ?? 0
            TableLayoutProbe.rows[key] = sorted.map { ($0.y - top, $0.maxY - $0.y) }
            if e.misfit { TableLayoutProbe.misfit.insert(key) }
        }
    }
}

extension NSAttributedString.Key {
    /// What a plain-text copy puts in place of this range: list markers, table cell breaks, a code block's label.
    static let messageCopy = NSAttributedString.Key("flockbook.messageCopy")
}

/// Not editable, selectable, no own scrolling: SwiftUI sizes it from `MessageContent`.
final class MessageTextView: NSTextView {
    private(set) var contentID = -1
    /// Folded height (the rest is cut, the bottom fades), or nil.
    var fold: CGFloat? { didSet { needsLayout = true } }
    private let fade = CAGradientLayer()

    static func make() -> MessageTextView {
        let tv = MessageTextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.size = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.usesFontPanel = false
        // No idle-time layout chunks on the main thread. (Non-contiguous layout made the churn check's stalls longer.)
        tv.layoutManager?.backgroundLayoutEnabled = false
        tv.clipsToBounds = true
        tv.linkTextAttributes = [.foregroundColor: ReadingColor.NS.link, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                 .cursor: NSCursor.pointingHand]
        return tv
    }

    func load(_ content: MessageContent) {
        textStorage?.setAttributedString(content.text)
        contentID = content.id
    }

    override func layout() {
        super.layout()
        guard let fold, bounds.height >= fold - 0.5 else { if layer?.mask != nil { layer?.mask = nil }; return }
        wantsLayer = true
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        let h = max(1, bounds.height)
        fade.locations = [0, NSNumber(value: Double(max(0, (h - 48) / h))), 1]
        // A flipped view: location 0 is the top.
        fade.startPoint = CGPoint(x: 0.5, y: isFlipped ? 0 : 1)
        fade.endPoint = CGPoint(x: 0.5, y: isFlipped ? 1 : 0)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = bounds
        layer?.mask = fade
        CATransaction.commit()
    }

    /// The selection as plain text: list markers as "- " / "1. ", table cells split by tabs, code labels left out.
    func plainText(_ range: NSRange) -> String {
        guard let storage = textStorage, range.length > 0 else { return "" }
        let s = storage.string as NSString
        var out = ""
        storage.enumerateAttribute(.messageCopy, in: range) { v, r, _ in
            if let v = v as? String { out += v } else { out += s.substring(with: r).replacingOccurrences(of: "\u{FFFC}", with: "") }
        }
        return out
    }

    /// Copy, drag and Services write plain text only: rich text would bring back code labels and raw list markers.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        let text = selectedRanges.map { plainText($0.rangeValue) }.filter { !$0.isEmpty }.joined(separator: "\n")
        return pboard.setString(text, forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        if let code = codeBlock(at: convert(event.locationInWindow, from: nil)) {
            let item = menu.addItem(withTitle: "Copy Code", action: #selector(copyCode(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = code.code
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "").target = self
        return menu
    }

    private func codeBlock(at p: NSPoint) -> CodeTextBlock? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let i = min(characterIndexForInsertion(at: p), storage.length - 1)
        let style = storage.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle
        return style?.textBlocks.first { $0 is CodeTextBlock } as? CodeTextBlock
    }

    @objc private func copyCode(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}

/// A code block: rounded fill and hairline border; the code it holds for "Copy Code".
final class CodeTextBlock: NSTextBlock {
    var code = ""
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView, characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let r = frameRect.inset(top: width(for: .margin, edge: .minY), bottom: width(for: .margin, edge: .maxY))
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: Radius.card, yRadius: Radius.card)
        ReadingColor.NS.codeFill.setFill(); path.fill()
        ReadingColor.NS.hairline.setStroke(); path.lineWidth = 0.5; path.stroke()
    }
}

/// A block quote: a 3 pt bar on the leading side.
final class QuoteTextBlock: NSTextBlock {
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView, characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let r = frameRect.inset(top: width(for: .margin, edge: .minY), bottom: width(for: .margin, edge: .maxY))
        ReadingColor.NS.primary(0.16).setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: 3, height: r.height), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// A thematic break: a 120 pt hairline in the middle of the column.
final class RuleTextBlock: NSTextBlock {
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView, characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let r = frameRect.inset(top: width(for: .margin, edge: .minY), bottom: width(for: .margin, edge: .maxY))
        ReadingColor.NS.hairline.setFill()
        NSRect(x: r.midX - 60, y: r.midY.rounded(.down), width: 120, height: 1).fill()
    }
}

/// A table: rounded outer border (the cells draw their own fills and row lines).
final class RoundedTextTable: NSTextTable {
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView, characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let r = frameRect.inset(top: width(for: .margin, edge: .minY), bottom: width(for: .margin, edge: .maxY))
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: Radius.card, yRadius: Radius.card)
        ReadingColor.NS.primary(0.14).setStroke(); path.lineWidth = 0.5; path.stroke()
    }
}

private extension NSRect {
    func inset(top: CGFloat, bottom: CGFloat) -> NSRect { NSRect(x: minX, y: minY + top, width: width, height: max(0, height - top - bottom)) }
}
