import Foundation

/// An 8-bit sRGB colour.
public struct RGB8: Sendable, Hashable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
}

/// The colours of one Ghostty theme, with Ghostty's defaults for what the theme leaves out.
public struct TerminalTheme: Sendable, Hashable {
    public var name: String
    public var background: RGB8
    public var foreground: RGB8
    /// The 16 ANSI colours.
    public var palette: [RGB8]
    public var cursor: RGB8
    public var cursorText: RGB8
    public var selectionBackground: RGB8
    public var selectionForeground: RGB8
}

/// The theme for light and for dark appearance (the same theme twice when the config names one).
public struct GhosttyThemes: Sendable, Hashable {
    public var light: TerminalTheme
    public var dark: TerminalTheme
    public func theme(dark: Bool) -> TerminalTheme { dark ? self.dark : light }
}

/// Why the Ghostty theme cannot be used.
public enum GhosttyThemeProblem: Error, Sendable, Hashable {
    case noConfig
    case noTheme
    case themeNotFound(String)
    case badTheme(String)
    case badValue(String)

    public var reason: String { "" }
}

/// Reads the user's Ghostty config the way Ghostty does, for the theme's colours only. Never writes.
public enum GhosttyConfig {
    public static func load(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment,
                            resources: String?) -> Result<GhosttyThemes, GhosttyThemeProblem> {
        .failure(.noConfig)
    }

    public static func color(_ s: String) -> RGB8? { nil }
}
