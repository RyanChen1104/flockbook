import AppKit
import HerdrKit
import SwiftUI

/// `--snapshot-statusline <dir>`: Claude Code's status row over the composer (StatusLineBar), offscreen, light and
/// dark, one row and open, a nearly full context, a narrow pane, and a line without Claude Code's facts; the Agents
/// tab's switch in each state and its sheets. Also checks the model side: a Claude pane's line is read, other agents
/// and empty lines show nothing. Reads and writes no settings file.
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

        // The row over the composer: the tags in one row, the chevron at the right (the own lines are in the open view).
        for dark in [false, true] {
            for expanded in [false, true] {
                let n = "\(expanded ? "expanded" : "row") \(dark ? "dark" : "light")"
                let r = await shotBar(record, expanded: expanded, dark: dark, path: "\(dir)/statusline-\(expanded ? "expanded" : "row")-\(dark ? "dark" : "light").png")
                step("\(n): the window stays off every screen", r.away)
                step("\(n): right over the composer (gap \(Int(r.gap)) pt), \(Int(r.bar.height)) pt tall",
                     r.gap >= 0 && r.gap <= 8 && (expanded ? r.bar.height > 40 : r.bar.height > 10 && r.bar.height < 30))
                if expanded {
                    step("\(n): open, every tag and no raw line (\(StatusLineProbe.openTags.map(String.init) ?? "nil") of \(record.tags.count) tags)",
                         StatusLineProbe.openTags == record.tags.count && record.tags.count == 10)
                } else {
                    step("\(n): Claude Code's tags, then the owner's that fit, and the chevron (\(String(describing: r.fit)))",
                         (r.fit.map { $0.shown > 4 && $0.shown < record.tags.count && $0.chevron } ?? false) && !r.plain)
                }
            }
            let hot = StatusLineRecord(lines: record.lines, info: ClaudeStatusInfo(json: Data(#"""
                {"session_id":"s-shot","model":{"display_name":"Opus 5.5"},"effort":{"level":"high"},"cost":{"total_cost_usd":7.91},
                 "context_window":{"context_window_size":1000000,"used_percentage":86.2}}
                """#.utf8)), time: Date())
            let r = await shotBar(hot, expanded: false, dark: dark, path: "\(dir)/statusline-hot-\(dark ? "dark" : "light").png")
            step("context 86% \(dark ? "dark" : "light"): off every screen, the context tag is orange", r.away && r.warn)
        }
        let narrow = await shotBar(record, expanded: false, dark: false, width: 380, path: "\(dir)/statusline-narrow-light.png")
        step("narrow pane: the tags that fit, then the chevron (\(String(describing: narrow.fit)))",
             narrow.away && (narrow.fit.map { $0.shown > 0 && $0.shown < 4 && $0.chevron } ?? false) && narrow.bar.height < 30)
        let factsOnly = await shotBar(StatusLineRecord(lines: [], info: info, time: Date()), expanded: false, dark: false, path: "\(dir)/statusline-facts-only-light.png")
        step("facts, no own line: every tag, no chevron (\(String(describing: factsOnly.fit)))", factsOnly.away && factsOnly.fit == .init(shown: 4, chevron: false))
        let plain = await shotBar(StatusLineRecord(lines: record.lines, info: nil, time: Date()), expanded: false, dark: false, path: "\(dir)/statusline-plain-light.png")
        step("no facts: the owner's parts as tags, one row (\(String(describing: plain.fit)))",
             plain.away && !plain.plain && plain.bar.height < 30 && (plain.fit?.shown ?? 0) > 0)

        // Settings > Agents: the switch in each state, and the sheets.
        for dark in [false, true] {
            for (n, st) in [("off", StatusLineSetup.State.off), ("on", .on), ("replaced", .replaced), ("moved", .moved)] {
                step("settings \(n) \(dark ? "dark" : "light"): off every screen",
                     await shotView(SettingsView(tab: .agents, statusLine: .preview(st)), width: 520, dark: dark, path: "\(dir)/settings-statusline-\(n)-\(dark ? "dark" : "light").png"))
            }
            for (n, st) in [("on", StatusLineSetup.State.off), ("off", .on), ("fix", .moved)] {
                step("sheet turn \(n) \(dark ? "dark" : "light"): off every screen",
                     await shotView(StatusLineSheet(setup: .preview(st)), width: 520, dark: dark, path: "\(dir)/statusline-sheet-turn-\(n)-\(dark ? "dark" : "light").png"))
            }
        }
        print("snapshot-statusline: \(failures == 0 ? "PASS" : "FAIL x\(failures)"), written to \(dir)")
        exit(failures == 0 ? 0 : 1)
    }

    /// The bottom of a pane: a reply, the status row and the composer. Returns the row's frame, its gap over the
    /// composer, what fit in one row, whether the owner's line stands in for the tags, whether the context tag is
    /// orange, and whether the window touched no screen.
    @MainActor private static func shotBar(_ record: StatusLineRecord, expanded: Bool, dark: Bool, width: CGFloat = 900, path: String) async
        -> (bar: CGRect, gap: CGFloat, fit: StatusTagRow.Fit?, plain: Bool, warn: Bool, away: Bool) {
        let size = NSSize(width: width, height: 360)
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
                StatusLineBar(record: record, expanded: expanded)
                ComposerView(agentName: "claude", draft: ComposerDraft(), onSend: { _ in })
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { composer = $0 }
                    .inputColumn()
            }
        }
        .environment(\.flatGlass, true).environment(\.colorScheme, dark ? .dark : .light)
        .frame(width: size.width, height: size.height)
        StatusLineProbe.frame = .zero; StatusLineProbe.fit = nil; StatusLineProbe.plain = false; StatusLineProbe.warn = false; StatusLineProbe.openTags = nil
        let away = await render(view, size: size, dark: dark, path: path)
        return (StatusLineProbe.frame, composer.minY - StatusLineProbe.frame.maxY, StatusLineProbe.fit, StatusLineProbe.plain, StatusLineProbe.warn, away)
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
