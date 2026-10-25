import AppKit
import CoreText
import HerdrKit
import SwiftTerm

/// The terminal's font when an installed Nerd Font can give the prompt icons. Prompt themes (powerlevel10k, starship)
/// draw icons from the Private Use Area (U+E000–F8FF); no system font has them, so Core Text drew a box. SwiftTerm
/// draws the four Powerline arrows itself. Core Text ignores a fallback list on the system monospaced font (SwiftTerm's
/// default), so the icons need a named font: Ghostty's own font when it has them, else Menlo with the Nerd Font as its
/// fallback. Without a Nerd Font the terminal keeps SwiftTerm's font.
@MainActor enum TerminalFont {
    enum Choice: Equatable {
        /// Ghostty's `font-family` (installed, with the icons): the terminal's font.
        case ghostty(String)
        /// Menlo, falling back to this Nerd Font family.
        case fallback(String)
    }

    /// A Private Use Area icon every Nerd Font has (the git branch, U+F126).
    static let probe: UniChar = 0xF126

    /// Ghostty's first installed `font-family` when it has the icons; else the first family with them: Ghostty's
    /// others, then installed Nerd Fonts (Symbols only, then mono, then any, `… NF` like p10k's MesloLGS NF last).
    static func choose(ghostty: [String] = GhosttyConfig.fontFamilies(),
                       installed: [String] = NSFontManager.shared.availableFontFamilies) -> Choice? {
        let have = Set(installed)
        if let first = ghostty.first(where: have.contains), hasIcons(first) { return .ghostty(first) }
        func rank(_ f: String) -> Int? {
            if f.hasPrefix("Symbols Nerd Font") { return 0 }
            if f.hasSuffix("Nerd Font Mono") { return 1 }
            if f.contains("Nerd Font") { return 2 }
            if f.hasSuffix(" NF") || f.contains(" NF ") { return 3 }
            return nil
        }
        let nerd = installed.compactMap { f in rank(f).map { (f, $0) } }.sorted { ($0.1, $0.0) < ($1.1, $1.0) }.map(\.0)
        return (ghostty.filter(have.contains) + nerd).first(where: hasIcons).map(Choice.fallback)
    }

    /// The family draws U+F126 itself (not through a fallback).
    static func hasIcons(_ family: String) -> Bool {
        guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) else { return false }
        var c = probe, g: CGGlyph = 0
        return CTFontGetGlyphsForCharacters(font as CTFont, &c, &g, 1) && g != 0
    }

    /// Found once per launch (a font installed later shows after a restart). Tests set it.
    static var choice: Choice? = choose()

    /// The terminal's font at `base`'s size; `base` itself without a choice.
    static func font(_ base: NSFont, choice: Choice? = choice) -> NSFont {
        let size = base.pointSize
        switch choice {
        case nil: return base
        case .ghostty(let family):
            return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) ?? base
        case .fallback(let family):
            guard let menlo = NSFont(name: "Menlo-Regular", size: size) else { return base }
            let cascade = [NSFontDescriptor(fontAttributes: [.family: family])]
            return NSFont(descriptor: menlo.fontDescriptor.addingAttributes([.cascadeList: cascade]), size: size) ?? base
        }
    }

    /// Gives a terminal view its font (keeps its size).
    static func apply(_ tv: TerminalView) { tv.font = font(tv.font) }
}
