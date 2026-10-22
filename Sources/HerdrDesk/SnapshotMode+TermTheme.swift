import AppKit
import HerdrKit
import Observation
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
        let ink = palette(["3a3f4b", "e06c75", "98c379", "e5c07b", "61afef", "c678dd", "56b6c2", "abb2bf",
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
        // (The cursor's getter shows nothing: SwiftTerm draws the foreground when no colour was set. Pixels below.)
        step("Flockbook again: transparent, default selection", tv.backgroundOpacity == 0
             && same(tv.selectedTextBackgroundColor, NSColor(srgbRed: 0, green: 166 / 255, blue: 178 / 255, alpha: 1)))

        // The live terminal: a fake herdr sends one frame with the 8 ANSI colours.
        let script = tmp + "/herdr"
        let text = "$ ls\r\n" + (30...37).map { "\u{1b}[\($0)mcolour\($0 - 30)\u{1b}[0m" }.joined(separator: " ") + "\r\n$ "
        let frame = #"{"type":"terminal.frame","seq":1,"full":true,"width":80,"height":24,"bytes":"\#(Data(text.utf8).base64EncodedString())"}"#
        try? "#!/bin/sh\necho '\(frame)'\nsleep 8\n".write(toFile: script, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        TerminalNSView.testLauncher = [script]
        defer { TerminalNSView.testLauncher = nil }
        let model = AppModel(store: .preview)
        func terminalView(_ v: NSView) -> TerminalView? { (v as? TerminalView) ?? v.subviews.lazy.compactMap(terminalView).first }
        for (mode, dark) in [(TerminalColors.ghostty, false), (.ghostty, true), (.flockbook, false), (.flockbook, true)] {
            AppDefaults.store.set(mode.rawValue, forKey: TerminalColors.key)
            let size = NSSize(width: 640, height: 300), tag = "\(mode.rawValue) \(dark ? "dark" : "light")"
            let (win, host) = offscreen(ZStack { WindowSurface(glass: .off)
                ObservedTerminal(client: model.store.client, paneId: "w1:p9", terminalId: "term_theme\(mode)\(dark)", writable: true, focused: false) }, size)
            win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try? await Task.sleep(for: .milliseconds(1500))
            let path = "\(dir)/termtheme\(mode == .flockbook ? "-flockbook" : "")\(dark ? "-dark" : "").png"
            capture(win, to: path)
            let at = pixels(path, host), px = at?(size.width / 2, size.height - 12)
            // The cursor as drawn: in its cell, the pixel farthest from the background.
            var cursor: NSColor?
            if let tv = terminalView(host), let at, let bg = srgb(px) {
                var r = tv.convert(tv.caretFrame, to: host)
                if !host.isFlipped { r.origin.y = host.bounds.height - r.maxY }
                var best = -1.0
                for x in stride(from: r.minX, to: r.maxX, by: 0.5) { for y in stride(from: r.minY, to: r.maxY, by: 0.5) {
                    guard let c = srgb(at(x, y)) else { continue }
                    let d = abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent) + abs(c.blueComponent - bg.blueComponent)
                    if d > best { best = d; cursor = c }
                } }
            }
            let wantCursor = mode == .ghostty ? (dark ? RGB8(0xff, 0xcc, 0x00) : RGB8(0xb8, 0x86, 0x0b)).ns
                : dark ? NSColor(srgbRed: 0.91, green: 0.91, blue: 0.918, alpha: 1) : NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)
            // The outline is antialiased and the capture is in the display's colours. Ghostty: nearer the theme's cursor
            // colour than its foreground. Flockbook: grey like the foreground (not the system's blue), nearer it than the
            // background.
            func distance(_ a: NSColor?, _ b: NSColor?) -> CGFloat {
                guard let a = srgb(a), let b = srgb(b) else { return .infinity }
                return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
            }
            let ok: Bool
            if mode == .ghostty { ok = distance(cursor, wantCursor) < distance(cursor, (dark ? RGB8(0xd0, 0xd6, 0xe0) : RGB8(0x3b, 0x32, 0x28)).ns) }
            else if let c = srgb(cursor) {
                let parts = [c.redComponent, c.greenComponent, c.blueComponent]
                ok = parts.max()! - parts.min()! < 0.08 && distance(c, wantCursor) < distance(c, px)
            } else { ok = false }
            step("\(tag): the cursor is drawn in \(mode == .ghostty ? "the theme's cursor colour" : "the foreground") (\(hex(cursor)), want \(hex(wantCursor)))", ok)
            win.orderOut(nil)
            guard mode == .ghostty else { continue }
            // The same colour as a plain view of the theme's background, through the same capture (display colour space).
            let (ref, refHost) = offscreen(Color(nsColor: (dark ? inkBg : paperBg).ns), NSSize(width: 40, height: 40))
            ref.appearance = win.appearance
            try? await Task.sleep(for: .milliseconds(300))
            capture(ref, to: "\(dir)/termtheme-ref.png")
            let want = pixels("\(dir)/termtheme-ref.png", refHost)?(20, 20)
            ref.orderOut(nil)
            step("\(dark ? "dark" : "light"): the empty rows are exactly the theme's background (\(hex(px)) = \(hex(want)))", want != nil && same(px, want))
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
        step("no Ghostty config: the reason (\(themes.problem(.ghostty) ?? "none"))", themes.problem(.ghostty) == GhosttyThemeProblem.noConfig.reason)
        step("Flockbook colours: no reason", themes.problem(.flockbook) == nil)

        // The reason before any terminal read the theme, and Settings told when it changes.
        let fresh = TerminalThemes()
        fresh.source = .init(home: tmp + "/nohome", environment: [:], resources: nil)
        step("never read: the reason reads it (\(fresh.problem(.ghostty) ?? "none"))", fresh.problem(.ghostty) == GhosttyThemeProblem.noConfig.reason)
        final class Flag: @unchecked Sendable { var on = false }
        let told = Flag()
        withObservationTracking { _ = fresh.problem(.ghostty) } onChange: { told.on = true }
        fresh.source = .init(home: home, environment: [:], resources: nil)
        fresh.reload()
        step("a new read tells Settings (told \(told.on), reason \(fresh.problem(.ghostty) ?? "none"))", told.on && fresh.problem(.ghostty) == nil)
        // A colour Flockbook cannot read: the theme is used, the value named.
        try? "theme = light:Paper,dark:Ink\nbackground = black\n".write(toFile: ghostty + "/config", atomically: true, encoding: .utf8)
        fresh.reload()
        step("a skipped colour: the theme, and the reason names it (\(fresh.problem(.ghostty) ?? "none"))",
             fresh.theme(.ghostty, dark: false) != nil && fresh.problem(.ghostty)?.contains("background = black") == true)

        print("termtheme-test: pictures in \(dir)/termtheme{,-dark,-error-dark}.png")
        print("termtheme-test: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        NSApp.terminate(nil)
    }
}
