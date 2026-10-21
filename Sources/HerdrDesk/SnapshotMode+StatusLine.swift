import AppKit
import HerdrKit
import SwiftUI

/// `--snapshot-statusline <dir>`: Claude Code's status line under the composer (StatusLineBar), offscreen, light and
/// dark, one line and expanded; the Agents tab's switch in each state and its sheets. Also checks the model side: a
/// Claude pane's line is read, other agents and empty lines show nothing. Reads and writes no settings file.
extension SnapshotRunner {
    static func runStatusLine(dir: String) {
        Task { @MainActor in await statusLine(dir: dir) }
    }

    @MainActor private static func statusLine(dir: String) async {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var failures = 0
        func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("snapshot-statusline: \(n) \(ok ? "ok" : "FAIL")") }
        let esc = "\u{1B}"
        let info = ClaudeStatusInfo(json: Data(#"""
            {"session_id":"s-shot","model":{"display_name":"Opus 5.5"},"effort":{"level":"high"},"cost":{"total_cost_usd":3.274},
             "context_window":{"context_window_size":1000000,"used_percentage":41.6}}
            """#.utf8))
        let line = "\(esc)[38;5;141mOpus 5.5\(esc)[0m \(esc)[2m·\(esc)[0m \(esc)[36m⎇ main\(esc)[0m \(esc)[2m·\(esc)[0m ctx \(esc)[33m42%\(esc)[0m "
            + "\(esc)[2m·\(esc)[0m turn \(esc)[32m$0.18\(esc)[0m \(esc)[2m·\(esc)[0m session \(esc)[32m$3.27\(esc)[0m \(esc)[2m·\(esc)[0m "
            + "day \(esc)[1m$11.40\(esc)[0m/$25 \(esc)[2m·\(esc)[0m month \(esc)[1;31m$212\(esc)[0m/$300 \(esc)[97mwhite\(esc)[0m"
        let record = StatusLineRecord(lines: ANSIText.lines(line + "\n\(esc)[2mrate limit 5h: 23% · 7d: 61%\(esc)[0m"), info: info, time: Date())

        // The model: the probe stands in for the wrapper's files.
        let store = HerdrStore.preview
        func pane(_ kind: String) -> Pane {
            Pane(id: "p-\(kind)", terminalId: "term_\(kind)", cwd: "~/work", agent: Agent(name: kind, kind: kind, status: .idle, sessionId: "s-\(kind)", title: kind))
        }
        let claude = pane("claude"), codex = pane("codex")
        let model = AppModel(store: store)
        StatusLineProbe.injected = ["s-claude": record, "s-codex": record]
        model.checkStatusLine(for: claude)
        model.checkStatusLine(for: codex)
        step("a Claude pane's line is read", model.statusLines[claude.id] == record)
        step("another agent (codex): no line", model.statusLines[codex.id] == nil)
        StatusLineProbe.injected = ["s-claude": StatusLineRecord(lines: [], info: nil, time: Date())]
        model.checkStatusLine(for: claude)
        step("nothing to show: no line", model.statusLines[claude.id] == nil)
        StatusLineProbe.injected = [:]
        model.checkStatusLine(for: claude)
        step("no saved line for the session: no line", model.statusLines[claude.id] == nil)
        step("colours that vanish on the background use the line's own",
             StatusLineBar.color("#ffffff", dark: false) == nil && StatusLineBar.color("#000000", dark: true) == nil
             && StatusLineBar.color("#ffffff", dark: true) != nil && StatusLineBar.color("#00cd00", dark: false) != nil)
        step("facts: model, context, cost marked as an estimate (\(StatusLineBar.facts(info) ?? "nil"))",
             StatusLineBar.facts(info) == "Opus 5.5 · context 42% of 1M · session $3.27 (estimate)")

        // The bar under the composer.
        for dark in [false, true] {
            for expanded in [false, true] {
                let r = await shotBar(record, expanded: expanded, dark: dark, path: "\(dir)/statusline-\(expanded ? "expanded" : "line")-\(dark ? "dark" : "light").png")
                step("\(expanded ? "expanded" : "one line") \(dark ? "dark" : "light"): the window stays off every screen", r.away)
                step("\(expanded ? "expanded" : "one line") \(dark ? "dark" : "light"): right under the composer (gap \(Int(r.gap)) pt), \(Int(r.bar.height)) pt tall",
                     r.gap >= 0 && r.gap <= 4 && (expanded ? r.bar.height > 30 : r.bar.height < 20))
            }
        }

        // Settings > Agents: the switch in each state, and the sheets.
        for dark in [false, true] {
            for (n, st) in [("off", StatusLineSetup.State.off), ("on", .on), ("replaced", .replaced)] {
                step("settings \(n) \(dark ? "dark" : "light"): off every screen",
                     await shotView(SettingsView(tab: .agents, statusLine: .preview(st)), width: 520, dark: dark, path: "\(dir)/settings-statusline-\(n)-\(dark ? "dark" : "light").png"))
            }
            for (n, st) in [("on", StatusLineSetup.State.off), ("off", .on)] {
                step("sheet turn \(n) \(dark ? "dark" : "light"): off every screen",
                     await shotView(StatusLineSheet(setup: .preview(st)), width: 520, dark: dark, path: "\(dir)/statusline-sheet-turn-\(n)-\(dark ? "dark" : "light").png"))
            }
        }
        print("snapshot-statusline: \(failures == 0 ? "PASS" : "FAIL x\(failures)"), written to \(dir)")
        exit(failures == 0 ? 0 : 1)
    }

    /// The bottom of a pane: a reply, the composer and the status line. Returns the bar's frame, its gap under the
    /// composer, and whether the window touched no screen.
    @MainActor private static func shotBar(_ record: StatusLineRecord, expanded: Bool, dark: Bool, path: String) async -> (bar: CGRect, gap: CGFloat, away: Bool) {
        let size = NSSize(width: 900, height: 360)
        var composer = CGRect.zero
        let view = ZStack(alignment: .bottom) {
            Color(nsColor: .textBackgroundColor)
            VStack(spacing: 0) {
                Spacer()
                HStack {
                    Spacer(minLength: 120)
                    UserBubble(text: "Show me what the deploy will cost.", size: .m)
                }
                .readingColumn(.m, .medium).padding(.bottom, 14)
                ComposerView(agentName: "claude", draft: ComposerDraft(), onSend: { _ in })
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { composer = $0 }
                    .inputColumn()
                StatusLineBar(record: record, expanded: expanded)
            }
        }
        .environment(\.flatGlass, true).environment(\.colorScheme, dark ? .dark : .light)
        .frame(width: size.width, height: size.height)
        StatusLineProbe.frame = .zero
        let away = await render(view, size: size, dark: dark, path: path)
        return (StatusLineProbe.frame, StatusLineProbe.frame.minY - composer.maxY, away)
    }

    @MainActor private static func shotView(_ v: some View, width: CGFloat, dark: Bool, path: String) async -> Bool {
        let fit = NSHostingController(rootView: v.environment(\.colorScheme, dark ? .dark : .light)).sizeThatFits(in: CGSize(width: width, height: 0))
        let size = NSSize(width: width, height: max(80, fit.height))
        return await render(ZStack(alignment: .top) { Color(nsColor: .windowBackgroundColor); v }
            .environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height), size: size, dark: dark, path: path)
    }

    @MainActor private static func render(_ view: some View, size: NSSize, dark: Bool, path: String) async -> Bool {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let win = OffscreenWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var away = true
        func check() { away = away && !NSScreen.screens.contains(where: { $0.frame.intersects(win.frame) }) }
        win.contentView = host; win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless(); check()
        for _ in 0..<8 { try? await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); check() }
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        win.orderOut(nil)
        return away
    }
}
