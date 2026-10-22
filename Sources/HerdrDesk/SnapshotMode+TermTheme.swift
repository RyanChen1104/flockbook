import AppKit
import HerdrKit
import SwiftTerm
import SwiftUI

extension ContentTests {
    /// The terminal in Ghostty-theme colours: a synthetic `light:Paper,dark:Ink` theme in a temp HOME (never the user's
    /// config), opaque background, palette, cursor and selection; back to Flockbook's colours; a theme that cannot be
    /// read falls back with a reason; the start error stays readable on the theme. Pictures of light, dark and error.
    static func termTheme() async {
        var failures = 0
        func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("termtheme-test: \(n) \(ok ? "ok" : "FAIL")") }
        // Catalog colours (Flockbook's caret, AppKit's defaults) throw on `redComponent`: compare in sRGB.
        func srgb(_ c: NSColor?) -> NSColor? { c?.usingColorSpace(.sRGB) }
        func same(_ p: NSColor?, _ q: NSColor?) -> Bool { ContentTests.same(srgb(p), srgb(q)) }
        func hex(_ c: NSColor?) -> String { ContentTests.hex(srgb(c)) }
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "fb-termtheme-\(getpid())", home = tmp + "/home", ghostty = home + "/.config/ghostty"
        try? fm.createDirectory(atPath: ghostty + "/themes", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmp) }
        func palette(_ hex: [String]) -> String { hex.enumerated().map { "palette = \($0.offset)=#\($0.element)" }.joined(separator: "\n") }
        let paper = palette(["3b3228", "b23a2c", "4d7a2a", "9a6a00", "2f5f9a", "8a3f8a", "2a7a7a", "d8cfbd",
                             "6b6052", "d0473a", "5e9632", "b88300", "3a74bd", "a64fa6", "339494", "fbf6ea"])
        let ink = palette(["14161f", "e06c75", "98c379", "e5c07b", "61afef", "c678dd", "56b6c2", "abb2bf",
                           "5c6370", "ff7a85", "b5e890", "ffd68a", "7cc4ff", "dc8ff0", "6fd3df", "ffffff"])
        try? "\(paper)\nbackground = #f4ecd8\nforeground = #3b3228\ncursor-color = #b8860b\nselection-background = #d8c8a8\n"
            .write(toFile: ghostty + "/themes/Paper", atomically: true, encoding: .utf8)
        try? "\(ink)\nbackground = #14161f\nforeground = #d0d6e0\ncursor-color = #ffcc00\nselection-background = #2c3448\n"
            .write(toFile: ghostty + "/themes/Ink", atomically: true, encoding: .utf8)
        try? "theme = light:Paper,dark:Ink\n".write(toFile: ghostty + "/config", atomically: true, encoding: .utf8)
        let themes = TerminalThemes.shared
        themes.source = .init(home: home, environment: [:], resources: nil)
        themes.reload()
        let before = AppDefaults.store.string(forKey: TerminalColors.key)
        AppDefaults.store.set(TerminalColors.ghostty.rawValue, forKey: TerminalColors.key)
        defer { AppDefaults.store.set(before, forKey: TerminalColors.key); themes.source = nil }
        let paperBg = RGB8(0xf4, 0xec, 0xd8), inkBg = RGB8(0x14, 0x16, 0x1f)

        // The view's colours, set and set back.
        let tv = TerminalView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        TerminalNSView.applyColors(tv, .light, mode: .ghostty)
        step("light: Paper's background, opaque (\(hex(tv.nativeBackgroundColor)), opacity \(tv.backgroundOpacity))",
             same(tv.nativeBackgroundColor, paperBg.ns) && tv.backgroundOpacity == 1)
        step("light: foreground, cursor, selection", same(tv.nativeForegroundColor, RGB8(0x3b, 0x32, 0x28).ns)
             && same(tv.caretColor, RGB8(0xb8, 0x86, 0x0b).ns) && same(tv.selectedTextBackgroundColor, RGB8(0xd8, 0xc8, 0xa8).ns))
        TerminalNSView.applyColors(tv, .dark, mode: .ghostty)
        step("dark: Ink's background and cursor (\(hex(tv.nativeBackgroundColor)))",
             same(tv.nativeBackgroundColor, inkBg.ns) && same(tv.caretColor, RGB8(0xff, 0xcc, 0x00).ns))
        TerminalNSView.applyColors(tv, .dark, mode: .flockbook)
        step("Flockbook again: transparent, default cursor and selection", tv.backgroundOpacity == 0
             && same(tv.caretColor, NSColor.selectedControlColor) && same(tv.selectedTextBackgroundColor, NSColor(srgbRed: 0, green: 166 / 255, blue: 178 / 255, alpha: 1)))

        // The live terminal: a fake herdr sends one frame with the 8 ANSI colours.
        let script = tmp + "/herdr"
        let text = "$ ls\r\n" + (30...37).map { "\u{1b}[\($0)mcolour\($0 - 30)\u{1b}[0m" }.joined(separator: " ") + "\r\n$ "
        let frame = #"{"type":"terminal.frame","seq":1,"full":true,"width":80,"height":24,"bytes":"\#(Data(text.utf8).base64EncodedString())"}"#
        try? "#!/bin/sh\necho '\(frame)'\nsleep 8\n".write(toFile: script, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        TerminalNSView.testLauncher = [script]
        defer { TerminalNSView.testLauncher = nil }
        let model = AppModel(store: .preview)
        for dark in [false, true] {
            let size = NSSize(width: 640, height: 300)
            let (win, host) = offscreen(ZStack { WindowSurface(glass: .off)
                ObservedTerminal(client: model.store.client, paneId: "w1:p9", terminalId: "term_theme\(dark)", writable: true, focused: false) }, size)
            win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try? await Task.sleep(for: .milliseconds(1500))
            let path = "\(dir)/termtheme\(dark ? "-dark" : "").png"
            capture(win, to: path)
            let px = pixels(path, host)?(size.width / 2, size.height - 12)
            step("\(dark ? "dark" : "light"): the empty rows are the theme's background (\(hex(px)))", same(px, (dark ? inkBg : paperBg).ns)
                 || px.map { abs($0.redComponent - (dark ? inkBg : paperBg).ns.redComponent) < 0.03 } == true)
            win.orderOut(nil)
        }

        // The start error on the dark theme: a card that stays readable.
        let fail = tmp + "/fail"
        try? "#!/bin/sh\necho 'env: herdr: No such file or directory' >&2\nexit 127\n".write(toFile: fail, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fail)
        TerminalNSView.testLauncher = [fail]
        TerminalProbe.startError = nil
        let (win, _) = offscreen(ZStack { WindowSurface(glass: .off)
            ObservedTerminal(client: model.store.client, paneId: "w1:p9", terminalId: "term_theme_fail", writable: true, focused: false) },
            NSSize(width: 640, height: 300))
        win.appearance = NSAppearance(named: .darkAqua)
        let t0 = Date()
        while TerminalProbe.startError == nil, Date().timeIntervalSince(t0) < 4 { try? await Task.sleep(for: .milliseconds(50)) }
        step("dark theme: the start error shows", TerminalProbe.startError != nil)
        try? await Task.sleep(for: .milliseconds(300))
        capture(win, to: "\(dir)/termtheme-error-dark.png")
        win.orderOut(nil)

        // A theme that cannot be read: Flockbook's colours, and the reason for Settings.
        themes.source = .init(home: tmp + "/nohome", environment: [:], resources: nil)
        themes.reload()
        TerminalNSView.applyColors(tv, .dark, mode: .ghostty)
        step("no Ghostty config: Flockbook's colours (opacity \(tv.backgroundOpacity))", tv.backgroundOpacity == 0)
        step("no Ghostty config: the reason (\(themes.problem ?? "none"))", themes.problem == GhosttyThemeProblem.noConfig.reason)

        print("termtheme-test: pictures in \(dir)/termtheme{,-dark,-error-dark}.png")
        print("termtheme-test: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        NSApp.terminate(nil)
    }
}
