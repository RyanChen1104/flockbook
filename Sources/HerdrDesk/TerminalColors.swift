import AppKit
import HerdrKit
import Observation
import SwiftTerm

/// Where the embedded terminal takes its colours: Flockbook's own (transparent, on the window surface) or the
/// user's Ghostty theme (opaque, exactly the theme's background).
enum TerminalColors: String, CaseIterable, Identifiable {
    case flockbook, ghostty
    static let key = "terminalColors"
    var id: String { rawValue }
    var label: String { switch self { case .flockbook: "Flockbook"; case .ghostty: "Ghostty theme" } }
    static var current: TerminalColors { TerminalColors(rawValue: AppDefaults.store.string(forKey: key) ?? "") ?? .flockbook }
}

/// The Ghostty theme, read when a terminal opens and on `reload()` (Settings), never per frame. Open terminals watch
/// `generation` and take a changed theme.
@MainActor @Observable final class TerminalThemes {
    static let shared = TerminalThemes()

    /// Where to read. Tests point it at synthetic files.
    struct Source { var home = NSHomeDirectory(); var environment = ProcessInfo.processInfo.environment; var resources: String? = TerminalThemes.ghosttyResources() }
    @ObservationIgnored var source: Source?
    @ObservationIgnored private(set) var loaded: Result<GhosttyThemes, GhosttyThemeProblem>?
    /// Goes up when a read finds other colours (or another reason), so open terminals take them.
    private(set) var generation = 0

    func reload() {
        let s = source ?? Source()
        let new = GhosttyConfig.load(home: s.home, environment: s.environment, resources: s.resources)
        if new != loaded { loaded = new; generation += 1 }
    }

    /// The theme to use, nil for Flockbook's colours (that setting, or a theme that cannot be read).
    func theme(_ mode: TerminalColors = .current, dark: Bool) -> TerminalTheme? {
        guard mode == .ghostty else { return nil }
        if loaded == nil { reload() }
        return try? loaded?.get().theme(dark: dark)
    }

    /// Why the Ghostty theme is not used, or which value of it is skipped, for Settings. Nil: Flockbook's colours, or
    /// the theme is used as it is. Reads the theme when nothing read it yet; a new read tells observers.
    func problem(_ mode: TerminalColors) -> String? {
        _ = generation
        guard mode == .ghostty else { return nil }
        if loaded == nil { reload() }
        switch loaded {
        case .failure(let p): return p.reason
        case .success(let t): return t.skipped.first.map { GhosttyThemeProblem.badColor($0).reason }
        case nil: return nil
        }
    }

    /// The theme's names for Settings: one name, or the light and the dark one. Nil: not read, or not usable.
    func names(_ mode: TerminalColors) -> String? {
        _ = generation
        guard mode == .ghostty, case .success(let t) = loaded else { return nil }
        return t.light.name == t.dark.name ? t.light.name : "\(t.light.name) (light), \(t.dark.name) (dark)"
    }

    /// Ghostty.app's resources folder, wherever the app is installed. Nil: no Ghostty.app.
    nonisolated static func ghosttyResources() -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")?
            .appending(path: "Contents/Resources/ghostty").path
    }
}

extension RGB8 {
    var ns: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    var term: SwiftTerm.Color { SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257) }
}
