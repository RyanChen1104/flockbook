import SwiftUI
import AppKit

/// Reading text size (docs/design/reading.md §2). All reading metrics come from here.
enum ReadingSize: String, CaseIterable, Identifiable {
    case s, m, l, xl
    static let key = "readingSize"
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var body: CGFloat { switch self { case .s: 15; case .m: 16; case .l: 18; case .xl: 20 } }
    var line: CGFloat { switch self { case .s: 24; case .m: 26; case .l: 29; case .xl: 32 } }
    /// Reading column width: the chosen width at size M, scaled with the text size.
    var column: CGFloat { ReadingWidth.current.points * body / 16 }
    var h1: CGFloat { switch self { case .s: 21; case .m: 22; case .l: 24; case .xl: 26 } }
    var h2: CGFloat { switch self { case .s: 19; case .m: 19; case .l: 21; case .xl: 23 } }
    var h3: CGFloat { switch self { case .s: 15; case .m: 16; case .l: 18; case .xl: 20 } }
    var inlineCode: CGFloat { switch self { case .s: 13; case .m: 14; case .l: 15.5; case .xl: 17.5 } }
    var codeBlock: CGFloat { switch self { case .s: 12; case .m: 13; case .l: 14; case .xl: 15 } }
    var codeLine: CGFloat { switch self { case .s: 18; case .m: 20; case .l: 21; case .xl: 23 } }
    var table: CGFloat { switch self { case .s: 13; case .m: 14; case .l: 15; case .xl: 16 } }
    /// Extra space for `Text.lineSpacing`: the target line height minus SF Pro's own (about 1.19 em).
    var lineSpacing: CGFloat { max(0, line - body * 1.19) }
    func larger() -> ReadingSize { Self.allCases[min(Self.allCases.count - 1, Self.allCases.firstIndex(of: self)! + 1)] }
    func smaller() -> ReadingSize { Self.allCases[max(0, Self.allCases.firstIndex(of: self)! - 1)] }
}

/// The corner radii of the content area (DESIGN: controls 6, cards 12, bubbles and the composer 16).
/// Panels and sheets take the system's own shape.
enum Radius {
    /// Buttons, hover rows, thumbnails, small boxes inside a card.
    static let control: CGFloat = 6
    /// Code blocks, tables, tool-call groups, approval card, overview cards, banners.
    static let card: CGFloat = 12
    /// Message bubbles and the composer.
    static let bubble: CGFloat = 16
    /// Keycaps (`Kbd`, 20 pt tall).
    static let key: CGFloat = 5
}

enum ReadingColor {
    static let hairline = Color.primary.opacity(0.09)

    /// The same colors for the message text views (AppKit), following light and dark at draw time.
    enum NS {
        private static func dyn(_ light: UInt32, _ dark: UInt32) -> NSColor {
            NSColor(name: nil) { a in
                let h = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1)
            }
        }
        /// `Color.primary.opacity(a)`.
        static func primary(_ alpha: CGFloat) -> NSColor {
            NSColor(name: nil) { a in
                var label = NSColor.labelColor
                a.performAsCurrentDrawingAppearance { label = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black }
                return label.withAlphaComponent(label.alphaComponent * alpha)
            }
        }
        static let link = dyn(0x0060C8, 0x5AA9FF)
        static let codeFill = dyn(0xF4F4F6, 0x232326)
        static let codeText = dyn(0x1D1D1F, 0xE8E8EA)
        static let hairline = primary(0.09)
        static let inlineFill = primary(0.08)
    }
}

/// Reading column width setting (Settings -> Reading width). Medium is the default.
enum ReadingWidth: String, CaseIterable, Identifiable {
    case narrow, medium, wide, full
    static let key = "readingWidth"
    var id: String { rawValue }
    var label: String { switch self { case .narrow: "Narrow"; case .medium: "Medium"; case .wide: "Wide"; case .full: "Full" } }
    /// Points at size M. Full is "as wide as the pane" (the pane clamps it).
    var points: CGFloat { switch self { case .narrow: 600; case .medium: 760; case .wide: 920; case .full: 2400 } }
    var sidePadding: CGFloat { self == .full ? 40 : 28 }
    static var current: ReadingWidth { ReadingWidth(rawValue: AppDefaults.store.string(forKey: key) ?? "") ?? .medium }
}

extension View {
    /// Puts this content in the conversation's reading column: at most `size.column` wide, inside the width setting's side
    /// padding, centred in the pane. The queue strip under the conversation uses it too, so its bubbles end where the
    /// user's bubbles end.
    func readingColumn(_ size: ReadingSize, _ width: ReadingWidth, alignment: Alignment = .leading, vertical: CGFloat = 0) -> some View {
        frame(maxWidth: size.column, alignment: alignment)
            .padding(.horizontal, width.sidePadding).padding(.vertical, vertical)
            .frame(maxWidth: .infinity)
    }
}

/// The content column of the full-width screens (Overview, Needs you, Search). The same rule as the conversation's reading
/// column: at most `width` wide, centred in the detail area, so a wide or full-screen window does not leave the content
/// against the left edge. 960 holds three Overview cards (adaptive grid, 260 pt minimum).
@MainActor enum ScreenColumn {
    static let width: CGFloat = 960
    /// Side inset that centres the column in `area` wide (lists use it as content margins, so the whole width scrolls).
    static func margin(_ area: CGFloat) -> CGFloat { max(0, (area - width) / 2) }
    /// Test hook: (screen, column frame, area frame) in global coordinates. nil in the app.
    static var probe: ((String, CGRect, CGRect) -> Void)?
}

extension View {
    /// Puts this content in the centred screen column (see `ScreenColumn`). `name` labels the frames for tests.
    func screenColumn(_ name: String, alignment: Alignment = .topLeading) -> some View {
        modifier(ScreenColumnFrame(name: name, alignment: alignment))
    }
}

private struct ScreenColumnFrame: ViewModifier {
    let name: String
    let alignment: Alignment
    @State private var column = CGRect.zero
    @State private var area = CGRect.zero

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: ScreenColumn.width, alignment: alignment)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { column = $0; ScreenColumn.probe?(name, column, area) }
            .frame(maxWidth: .infinity, alignment: .center)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { area = $0; ScreenColumn.probe?(name, column, area) }
    }
}
