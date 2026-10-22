import Foundation
@testable import HerdrKit

/// The terminal's colours from the user's Ghostty theme: where Ghostty looks, the light/dark syntax, config-file,
/// user themes before built-in ones, config keys over the theme, and the reasons when it cannot be used.
/// Synthetic config and theme files in a temp HOME; the user's real Ghostty config is never read.
func checksGhosttyTheme() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "fb-ghostty-\(getpid())").path
    defer { try? fm.removeItem(atPath: root) }
    var n = 0
    /// A fresh HOME with its Ghostty folders (XDG default, Application Support) and a fake app's built-in themes.
    func fresh() throws -> (home: String, xdg: String, support: String, resources: String) {
        n += 1
        let home = "\(root)/h\(n)", xdg = home + "/.config/ghostty", support = home + "/Library/Application Support/com.mitchellh.ghostty"
        let resources = "\(root)/app\(n)/Contents/Resources/ghostty"
        for d in [xdg + "/themes", support, resources + "/themes"] { try fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        return (home, xdg, support, resources)
    }
    func write(_ path: String, _ text: String) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }
    func load(_ h: (home: String, xdg: String, support: String, resources: String), env: [String: String] = [:]) -> Result<GhosttyThemes, GhosttyThemeProblem> {
        GhosttyConfig.load(home: h.home, environment: env, resources: h.resources)
    }
    func theme(_ r: Result<GhosttyThemes, GhosttyThemeProblem>, dark: Bool = false) -> TerminalTheme? { try? r.get().theme(dark: dark) }
    func problem(_ r: Result<GhosttyThemes, GhosttyThemeProblem>) -> GhosttyThemeProblem? { if case .failure(let p) = r { p } else { nil } }
    let c = { (s: String) in GhosttyConfig.color(s) }

    // Colours: #RRGGBB or RRGGBB, any case, quoted or not.
    check(c("#AbCdEf") == RGB8(0xab, 0xcd, 0xef) && c("102030") == RGB8(0x10, 0x20, 0x30) && c("\"#010203\"") == RGB8(1, 2, 3),
          "ghostty: hex colours")
    check(c("nothex") == nil && c("#12345") == nil && c("") == nil && c("black") == nil, "ghostty: not a colour -> nil")
    check(c("#abc") == RGB8(0xaa, 0xbb, 0xcc) && c("F0a") == RGB8(0xff, 0, 0xaa), "ghostty: #rgb is #rrggbb")

    // A synthetic theme in the user's themes folder.
    let syn = """
    # a synthetic theme
    palette = 0=#000001
    palette = 1=#aa0000
    palette = 15=#ffffee
    palette = 200=#123456
    background = #101010
    foreground=e0e0e0
    cursor-color = #020202
    cursor-text = #030303
    selection-background = #040404
    selection-foreground = #050505
    theme = Other
    config-file = elsewhere
    """
    var h = try fresh()
    check(problem(load(h)) == .noConfig, "ghostty: no config file -> noConfig")
    try write(h.xdg + "/config", "font-size = 13\n")
    check(problem(load(h)) == .noTheme, "ghostty: config without theme or colours -> noTheme")
    try write(h.xdg + "/themes/Syn", syn)
    try write(h.xdg + "/config", "theme = Syn\n")
    let t = theme(load(h))
    check(t?.name == "Syn" && t?.background == RGB8(0x10, 0x10, 0x10) && t?.foreground == RGB8(0xe0, 0xe0, 0xe0),
          "ghostty: theme background and foreground (\(String(describing: t?.background)))")
    check(t?.palette.count == 16 && t?.palette[0] == RGB8(0, 0, 1) && t?.palette[1] == RGB8(0xaa, 0, 0) && t?.palette[15] == RGB8(0xff, 0xff, 0xee),
          "ghostty: theme palette 0-15")
    check(t?.palette[2] == RGB8(0xb5, 0xbd, 0x68), "ghostty: a palette entry the theme leaves out is Ghostty's default")
    check(t?.cursor == RGB8(2, 2, 2) && t?.cursorText == RGB8(3, 3, 3) && t?.selectionBackground == RGB8(4, 4, 4) && t?.selectionForeground == RGB8(5, 5, 5),
          "ghostty: cursor and selection colours")
    check(theme(load(h), dark: true) == t, "ghostty: one theme -> the same in dark")

    // What a theme leaves out: Ghostty's defaults; selection is the inverted background and foreground.
    try write(h.xdg + "/themes/Bare", "palette = 3=#333300\n")
    try write(h.xdg + "/config", "theme = Bare\n")
    let bare = theme(load(h))
    check(bare?.background == RGB8(0x28, 0x2c, 0x34) && bare?.foreground == RGB8(0xff, 0xff, 0xff), "ghostty: no background/foreground -> Ghostty's defaults")
    check(bare?.selectionBackground == bare?.foreground && bare?.selectionForeground == bare?.background, "ghostty: no selection colours -> inverted")
    check(bare?.cursor == bare?.foreground && bare?.cursorText == bare?.background, "ghostty: no cursor colours -> foreground and background")

    // Keys in the config override the theme, before or after the theme line; an empty value resets to the default.
    try write(h.xdg + "/config", "background = #0a0a0a\ntheme = Syn\npalette = 0x1=bb0000\nforeground =\n")
    let over = theme(load(h))
    check(over?.background == RGB8(10, 10, 10) && over?.palette[1] == RGB8(0xbb, 0, 0), "ghostty: config keys override the theme (0x index too)")
    check(over?.foreground == RGB8(0xff, 0xff, 0xff), "ghostty: an empty value in the config resets to Ghostty's default")
    try write(h.xdg + "/config", "theme = Syn\nbackground = not-a-colour\n")
    check(theme(load(h))?.background == RGB8(0x10, 0x10, 0x10), "ghostty: a bad colour in the config is skipped")
    check((try? load(h).get())?.skipped == ["background = not-a-colour"], "ghostty: a skipped colour is reported (\(String(describing: (try? load(h).get())?.skipped)))")
    try write(h.xdg + "/config", "theme = Syn\npalette = 4=blue\n")
    check((try? load(h).get())?.skipped == ["palette = 4=blue"], "ghostty: a skipped palette colour is reported")
    check(GhosttyThemeProblem.badColor("background = black").reason.contains("background = black"), "ghostty: the skipped value's reason names it")
    try write(h.xdg + "/config", "background = #0b0b0b\n")
    let only = theme(load(h))
    check(only?.background == RGB8(11, 11, 11) && only?.name == "Ghostty config", "ghostty: colours without a theme -> those colours")

    // light:/dark: in either order, with spaces; one side alone is not valid.
    try write(h.xdg + "/themes/Light One", "background = #fafafa\n")
    try write(h.xdg + "/config", "theme = dark: Syn , light:Light One\n")
    let pair = try? load(h).get()
    check(pair?.light.name == "Light One" && pair?.light.background == RGB8(0xfa, 0xfa, 0xfa) && pair?.dark.name == "Syn",
          "ghostty: theme = dark:A,light:B")
    try write(h.xdg + "/config", "theme = light:Light One\n")
    check(problem(load(h)) == .badValue("light:Light One"), "ghostty: light: without dark: -> badValue")
    try write(h.xdg + "/config", "theme = sub/Syn\n")
    check(problem(load(h)) == .badValue("sub/Syn"), "ghostty: a relative path -> badValue")

    // Where themes are found: the user's themes first, then the app's; an absolute path only there.
    try write(h.resources + "/themes/Syn", "background = #999999\n")
    try write(h.resources + "/themes/Shipped", "background = #888888\n")
    try write(h.xdg + "/config", "theme = Syn\n")
    check(theme(load(h))?.background == RGB8(0x10, 0x10, 0x10), "ghostty: the user's theme wins over the built-in one")
    try write(h.xdg + "/config", "theme = Shipped\n")
    check(theme(load(h))?.background == RGB8(0x88, 0x88, 0x88), "ghostty: a built-in theme from the app's resources")
    check(problem(GhosttyConfig.load(home: h.home, environment: [:], resources: nil)) == .themeNotFound("Shipped"), "ghostty: no Ghostty.app -> built-in not found")
    try write(root + "/abs/My Theme", "background = #777777\n")
    try write(h.xdg + "/config", "theme = \(root)/abs/My Theme\n")
    check(theme(load(h))?.background == RGB8(0x77, 0x77, 0x77), "ghostty: theme as an absolute path")
    try write(h.xdg + "/config", "theme = \(root)/abs/Syn\n")
    check(problem(load(h)) == .themeNotFound(root + "/abs/Syn"), "ghostty: a missing absolute path -> not found, no search")
    try write(h.home + "/mine/Tilde", "background = #666666\n")
    try write(h.xdg + "/config", "theme = ~/mine/Tilde\n")
    check(theme(load(h))?.background == RGB8(0x66, 0x66, 0x66), "ghostty: theme = ~/path is the home folder's")
    try write(h.xdg + "/config", "theme = light:~/mine/Tilde,dark:Syn\n")
    check((try? load(h).get())?.light.background == RGB8(0x66, 0x66, 0x66), "ghostty: light:~/path")
    // Only plain files are read: a device or a FIFO would block, a huge file is not a theme.
    try write(h.xdg + "/config", "theme = /dev/null\n")
    check(problem(load(h)) == .themeNotFound("/dev/null"), "ghostty: a device is not read (\(String(describing: problem(load(h)))))")
    try write(root + "/abs/Huge", "background = #555555\n" + String(repeating: "# padding\n", count: 120_000))
    try write(h.xdg + "/config", "theme = \(root)/abs/Huge\n")
    check(problem(load(h)) == .themeNotFound(root + "/abs/Huge"), "ghostty: a file over 1 MB is not read")
    try write(h.xdg + "/config", "theme = Nowhere\n")
    check(problem(load(h)) == .themeNotFound("Nowhere"), "ghostty: unknown name -> themeNotFound")
    try write(h.xdg + "/themes/Junk", "this is not a theme\n\u{0}\u{1}\n")
    try write(h.xdg + "/config", "theme = Junk\n")
    check(problem(load(h)) == .badTheme("Junk"), "ghostty: a theme file with no colours -> badTheme")

    // The config files: XDG then Application Support, `config` then `config.ghostty`; the later one wins.
    h = try fresh()
    try write(h.xdg + "/themes/Syn", syn)
    try write(h.xdg + "/config", "theme = Syn\nbackground = #000011\n")
    try write(h.xdg + "/config.ghostty", "background = #000022\n")
    check(theme(load(h))?.background == RGB8(0, 0, 0x22), "ghostty: config.ghostty after config")
    try write(h.support + "/config.ghostty", "background = #000033\n")
    check(theme(load(h))?.background == RGB8(0, 0, 0x33), "ghostty: Application Support after XDG")
    let xdgHome = root + "/xdgalt"
    try write(xdgHome + "/ghostty/config", "theme = Alt\n")
    try write(xdgHome + "/ghostty/themes/Alt", "background = #445566\n")
    let alt = GhosttyConfig.load(home: root + "/nohome", environment: ["XDG_CONFIG_HOME": xdgHome], resources: nil)
    check(theme(alt)?.background == RGB8(0x44, 0x55, 0x66), "ghostty: XDG_CONFIG_HOME for the config and the user's themes")

    // config-file: relative to its file, loaded after the file (so it wins), nested, `?` optional, cycles stop.
    h = try fresh()
    try write(h.xdg + "/themes/Syn", syn)
    try write(h.xdg + "/config", "config-file = parts/colors\nconfig-file = ?parts/missing\ntheme = Syn\nbackground = #000001\n")
    try write(h.xdg + "/parts/colors", "background = #000002\nconfig-file = deeper\n")
    try write(h.xdg + "/parts/deeper", "foreground = #000003\nconfig-file = ../config\n")
    let inc = theme(load(h))
    check(inc?.background == RGB8(0, 0, 2), "ghostty: config-file loads after its file and wins (\(String(describing: inc?.background)))")
    check(inc?.foreground == RGB8(0, 0, 3), "ghostty: nested config-file, relative to the including file")
    check(inc?.name == "Syn", "ghostty: a cycle back to the first file is skipped")
    try write(h.xdg + "/config", "config-file = \"parts/colors\"\ntheme = Syn\n")
    check(theme(load(h))?.background == RGB8(0, 0, 2), "ghostty: a quoted config-file path")

    // The reasons, for Settings.
    for p in [GhosttyThemeProblem.noConfig, .noTheme, .themeNotFound("X"), .badTheme("X"), .badValue("x"), .badColor("x")] {
        check(!p.reason.isEmpty, "ghostty: \(p) has a reason")
    }
    check(GhosttyThemeProblem.themeNotFound("Nord").reason.contains("Nord"), "ghostty: the reason names the theme")
}
