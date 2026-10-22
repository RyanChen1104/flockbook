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
    /// Colour lines that were not a colour, skipped (`key = value`).
    public var skipped: [String] = []
    public func theme(dark: Bool) -> TerminalTheme { dark ? self.dark : light }
}

/// Why the Ghostty theme cannot be used.
public enum GhosttyThemeProblem: Error, Sendable, Hashable {
    case noConfig
    case noTheme
    case themeNotFound(String)
    case badTheme(String)
    case badValue(String)
    case badColor(String)

    /// One line for Settings.
    public var reason: String {
        switch self {
        case .noConfig: "No Ghostty config file found."
        case .noTheme: "Ghostty's config sets no theme."
        case .themeNotFound(let name): "Ghostty theme “\(name)” not found."
        case .badTheme(let name): "Ghostty theme “\(name)” has no colors."
        case .badValue(let value): "Ghostty's theme setting “\(value)” is not valid."
        case .badColor(let line): "Ghostty's “\(line)” is not a color Flockbook can read; it is skipped."
        }
    }
}

/// Reads the user's Ghostty config the way Ghostty does, for the theme's colours only. Never writes.
/// - Config files, later wins: `$XDG_CONFIG_HOME/ghostty` (default `~/.config/ghostty`), then
///   `~/Library/Application Support/com.mitchellh.ghostty`; in each, `config` then `config.ghostty`.
/// - `config-file = [?]path`: relative to the file it is in, loaded after that file (so its keys win); a file
///   already read (a cycle) is skipped. A missing file is skipped, with or without `?`.
/// - `theme = name`, `theme = light:A,dark:B` (both, any order), an absolute path or `~/path`. A name is looked up in the
///   user's `themes` folder, then in Ghostty.app's (`resources` = `Ghostty.app/Contents/Resources/ghostty`).
/// - Colour keys in the config override the theme's; an empty value resets one to Ghostty's default; a value that is
///   not a colour is skipped and listed in `skipped`.
/// - Only plain files up to 1 MB are read (a device or a FIFO would block).
public enum GhosttyConfig {
    public static func load(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment,
                            resources: String?) -> Result<GhosttyThemes, GhosttyThemeProblem> {
        let fm = FileManager.default
        let files = configFiles(home: home, environment: environment).filter { isFile($0) }
        guard !files.isEmpty else { return .failure(.noConfig) }
        var seen = Set<String>()
        var themeValue: String?, config = Colors()
        for (key, value) in files.flatMap({ read($0, home: home, seen: &seen) }) {
            if key == "theme" { themeValue = value.isEmpty ? nil : value } else { config.set(key, value) }
        }
        guard let themeValue else {
            guard !config.isEmpty else { return .failure(.noTheme) }
            let t = config.resolved(name: "Ghostty config", over: Colors())
            return .success(GhosttyThemes(light: t, dark: t, skipped: config.bad))
        }
        guard let names = names(themeValue, home: home) else { return .failure(.badValue(themeValue)) }
        var skipped = config.bad
        let folders = [ghosttyFolder(home: home, environment: environment) + "/themes"] + (resources.map { [$0 + "/themes"] } ?? [])
        func theme(_ name: String) -> Result<TerminalTheme, GhosttyThemeProblem> {
            let path = name.hasPrefix("/") ? (isFile(name) ? name : nil) : folders.map { $0 + "/" + name }.first(where: isFile)
            guard let path, let data = fm.contents(atPath: path) else { return .failure(.themeNotFound(name)) }
            var colors = Colors()
            for (key, value) in lines(String(decoding: data, as: UTF8.self)) where key != "theme" && key != "config-file" { colors.set(key, value) }
            guard !colors.isEmpty else { return .failure(.badTheme(name)) }
            skipped = colors.bad + skipped
            return .success(config.resolved(name: (name as NSString).lastPathComponent, over: colors))
        }
        return theme(names.light).flatMap { light in
            names.dark == names.light ? .success(GhosttyThemes(light: light, dark: light)) : theme(names.dark).map { GhosttyThemes(light: light, dark: $0) }
        }.map { var t = $0; t.skipped = skipped; return t }
    }

    /// Ghostty's config files in load order (later wins). They may not exist.
    public static func configFiles(home: String, environment: [String: String]) -> [String] {
        [ghosttyFolder(home: home, environment: environment), home + "/Library/Application Support/com.mitchellh.ghostty"]
            .flatMap { [$0 + "/config", $0 + "/config.ghostty"] }
    }

    static func ghosttyFolder(home: String, environment: [String: String]) -> String {
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        return xdg + "/ghostty"
    }

    /// `#RRGGBB`, `RRGGBB` or `#RGB`, optionally in double quotes. Nil: anything else (X11 colour names are not read).
    public static func color(_ s: String) -> RGB8? {
        var hex = unquote(s.trimmingCharacters(in: .whitespaces))
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return RGB8(UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff))
    }

    /// Ghostty's defaults (`ghostty +show-config --default`).
    static let defaultBackground = RGB8(0x28, 0x2c, 0x34), defaultForeground = RGB8(0xff, 0xff, 0xff)
    static let defaultPalette: [RGB8] = [
        RGB8(0x1d, 0x1f, 0x21), RGB8(0xcc, 0x66, 0x66), RGB8(0xb5, 0xbd, 0x68), RGB8(0xf0, 0xc6, 0x74),
        RGB8(0x81, 0xa2, 0xbe), RGB8(0xb2, 0x94, 0xbb), RGB8(0x8a, 0xbe, 0xb7), RGB8(0xc5, 0xc8, 0xc6),
        RGB8(0x66, 0x66, 0x66), RGB8(0xd5, 0x4e, 0x53), RGB8(0xb9, 0xca, 0x4a), RGB8(0xe7, 0xc5, 0x47),
        RGB8(0x7a, 0xa6, 0xda), RGB8(0xc3, 0x97, 0xd8), RGB8(0x70, 0xc0, 0xb1), RGB8(0xea, 0xea, 0xea),
    ]

    /// The colour keys a theme or a config sets. `nil` in a slot: reset to the default (an empty value).
    struct Colors {
        enum Value { case rgb(RGB8), cellForeground, cellBackground }
        static let keys: Set<String> = ["background", "foreground", "cursor-color", "cursor-text", "selection-background", "selection-foreground"]
        var keys: [String: Value?] = [:]
        var palette: [Int: RGB8?] = [:]
        /// `key = value` lines whose value is not a colour.
        var bad: [String] = []
        var isEmpty: Bool { keys.isEmpty && palette.isEmpty }

        mutating func set(_ key: String, _ value: String) {
            if key == "palette" {
                let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, let i = GhosttyConfig.index(parts[0]), (0..<16).contains(i) else { return }
                if parts[1].isEmpty { palette[i] = .some(nil) } else if let c = GhosttyConfig.color(parts[1]) { palette[i] = c } else { bad.append("palette = \(value)") }
                return
            }
            guard Self.keys.contains(key) else { return }
            switch value {
            case "": keys[key] = .some(nil)
            case "cell-foreground": keys[key] = .cellForeground
            case "cell-background": keys[key] = .cellBackground
            default: if let c = GhosttyConfig.color(value) { keys[key] = .rgb(c) } else { bad.append("\(key) = \(value)") }
            }
        }

        /// These keys over `theme`'s, then Ghostty's defaults for the rest.
        func resolved(name: String, over theme: Colors) -> TerminalTheme {
            let k = theme.keys.merging(keys) { $1 }, p = theme.palette.merging(palette) { $1 }
            func plain(_ key: String) -> RGB8? { if case .rgb(let c)?? = k[key] { c } else { nil } }
            let bg = plain("background") ?? GhosttyConfig.defaultBackground, fg = plain("foreground") ?? GhosttyConfig.defaultForeground
            func value(_ key: String, _ fallback: RGB8) -> RGB8 {
                switch k[key] ?? nil { case .rgb(let c): c; case .cellForeground: fg; case .cellBackground: bg; case nil: fallback }
            }
            return TerminalTheme(name: name, background: bg, foreground: fg,
                                 palette: (0..<16).map { (p[$0] ?? nil) ?? GhosttyConfig.defaultPalette[$0] },
                                 cursor: value("cursor-color", fg), cursorText: value("cursor-text", bg),
                                 selectionBackground: value("selection-background", fg), selectionForeground: value("selection-foreground", bg))
        }
    }

    /// A palette index: decimal, or `0x`, `0o`, `0b`.
    static func index(_ s: String) -> Int? {
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where s.lowercased().hasPrefix(prefix) { return Int(s.dropFirst(2), radix: radix) }
        return Int(s)
    }

    /// `theme`'s value: the light and the dark name (the same name twice for one theme). Nil: not valid.
    static func names(_ value: String, home: String) -> (light: String, dark: String)? {
        func valid(_ n: String) -> Bool { !n.isEmpty && (n.hasPrefix("/") || !n.contains("/")) }
        func expand(_ n: String) -> String { n.hasPrefix("~/") ? home + n.dropFirst() : n }
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.contains(where: { $0.hasPrefix("light:") || $0.hasPrefix("dark:") }) else { let v = expand(value); return valid(v) ? (v, v) : nil }
        var light: String?, dark: String?
        for part in parts {
            if part.hasPrefix("light:") { light = expand(part.dropFirst(6).trimmingCharacters(in: .whitespaces)) }
            else if part.hasPrefix("dark:") { dark = expand(part.dropFirst(5).trimmingCharacters(in: .whitespaces)) }
            else { return nil }
        }
        guard let light, let dark, valid(light), valid(dark) else { return nil }
        return (light, dark)
    }

    /// One file's keys, then its `config-file`s' (in order), each read once.
    static func read(_ path: String, home: String, seen: inout Set<String>) -> [(String, String)] {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard !seen.contains(real), isFile(real), let data = FileManager.default.contents(atPath: real) else { return [] }
        seen.insert(real)
        var out: [(String, String)] = [], includes: [String] = []
        for (key, value) in lines(String(decoding: data, as: UTF8.self)) {
            if key == "config-file" { includes.append(value) } else { out.append((key, value)) }
        }
        let dir = (path as NSString).deletingLastPathComponent
        for var inc in includes {
            if inc.hasPrefix("?") { inc = unquote(String(inc.dropFirst())) }
            guard !inc.isEmpty else { continue }
            if inc.hasPrefix("~/") { inc = home + inc.dropFirst() }
            out += read(inc.hasPrefix("/") ? inc : dir + "/" + inc, home: home, seen: &seen)
        }
        return out
    }

    /// `key = value` lines; `#` comment lines and lines without `=` are skipped. Values lose surrounding quotes.
    static func lines(_ text: String) -> [(String, String)] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            return (key, unquote(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)))
        }
    }

    static func unquote(_ s: String) -> String {
        s.count >= 2 && s.hasPrefix("\"") && s.hasSuffix("\"") ? String(s.dropFirst().dropLast()) : s
    }

    /// A plain file (symlinks followed) of at most 1 MB: never a device, FIFO or folder.
    static func isFile(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG && st.st_size <= 1 << 20
    }
}
