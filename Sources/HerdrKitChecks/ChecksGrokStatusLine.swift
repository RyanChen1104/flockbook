import Foundation
@testable import HerdrKit

// Grok Build's status line, opt-in like Claude Code's: On puts our wrapper in `[ui.status_line]` of Grok's config.toml
// (text edited in place, the rest of the file as it was) and keeps the owner's section; Off puts that section back
// exactly. Grok's built-in line has no command to run, so the wrapper draws its items itself.
@MainActor func checksGrokStatusLine() async throws {
    let ours = ClaudeStatusLineSetting.command(wrapper: "/Applications/Flockbook.app/Contents/MacOS/flockbook-statusline", dir: "/h/Flockbook/statusline-grok")
    func on(_ text: String) throws -> (text: String, original: [String: Any]?) { try GrokStatusLineSetting.enabling(text, command: ours) }
    func off(_ text: String, _ original: [String: Any]?) throws -> String? { try GrokStatusLineSetting.disabling(text, command: ours, original: original) }
    func roundTrip(_ text: String) -> Bool {
        guard let e = try? on(text), e.text != text, GrokStatusLineSetting.state(e.text, command: ours, wasOn: true) == .on,
              let back = try? off(e.text, e.original) else { return false }
        return back == text
    }

    // Shapes of the owner's config.toml (synthetic): none, built-in, a command, a disabled one, one table among others.
    let none = "model = \"grok-4.7\"\n\n[ui]\ntheme = \"auto\"\n"
    let builtin = "[ui]\ntheme = \"auto\"\n\n[ui.status_line]\ntype = \"builtin\"   # mine\nitems = [\n  \"cwd\",\n  \"model\", \"cost\",\n]\npadding = 1\n\n[mcp]\nx = 1\n"
    let command = "[ui.status_line]\ntype = 'command'\ncommand = \"~/.grok/statusline.sh --x \\\"y\\\"\"\nrefresh_interval = 60"
    let disabled = "[ui.status_line]\ntype = \"off\"\n"
    for (name, t) in [("none", none), ("builtin", builtin), ("command", command), ("disabled", disabled), ("empty", "")] {
        check(roundTrip(t), "grok status line: on then off gives the file back exactly (\(name))")
    }

    let e = try on(builtin)
    check(e.text.contains("[ui.status_line]\ntype = \"command\"\ncommand = \"" + ours.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"\n")
          && e.text.contains("padding = 1") && !e.text.contains("items") && e.text.hasPrefix("[ui]\ntheme = \"auto\"\n\n") && e.text.hasSuffix("\n[mcp]\nx = 1\n"),
          "grok status line: ours in place of theirs, padding kept, the rest as it was\n\(e.text)")
    check(e.original?["type"] as? String == "builtin" && e.original?["items"] as? [String] == ["cwd", "model", "cost"], "grok status line: their built-in items kept \(String(describing: e.original))")
    check(GrokStatusLineSetting.currentCommand(e.text) == ours, "grok status line: the command read back")
    let c = try on(command)
    check(c.original?["type"] as? String == "command" && c.original?["command"] as? String == "~/.grok/statusline.sh --x \"y\"" && c.text.contains("refresh_interval = 60"),
          "grok status line: their command kept \(String(describing: c.original))")
    let n = try on(none)
    check((n.original?["type"] as? String) == "none" && n.text.hasPrefix(none) && n.text.contains("[ui.status_line]"), "grok status line: none: ours added at the end")
    // On again changes nothing; Off with ours not in changes nothing.
    check((try? on(e.text))?.text == e.text && (try? on(e.text))?.original == nil, "grok status line: on twice: no change")
    let untouched = try off(builtin, e.original)
    check(untouched == nil, "grok status line: off without ours: no change")

    // States.
    check(GrokStatusLineSetting.state(builtin, command: ours, wasOn: false) == .off && GrokStatusLineSetting.state(builtin, command: ours, wasOn: true) == .replaced,
          "grok status line: off, or replaced since")
    let movedCmd = ClaudeStatusLineSetting.command(wrapper: "/Volumes/X/Flockbook.app/Contents/MacOS/flockbook-statusline", dir: "/h/Flockbook/statusline-grok")
    let moved = e.text.replacingOccurrences(of: ours.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""), with: movedCmd)
    check(GrokStatusLineSetting.state(moved, command: ours, wasOn: true) == .moved, "grok status line: an older copy's path: moved")
    let fixed = try on(moved)
    check(fixed.original == nil && GrokStatusLineSetting.currentCommand(fixed.text) == ours && fixed.text.contains("padding = 1"), "grok status line: on fixes the path only")

    // Shapes Flockbook does not edit: refused, nothing written.
    for (name, t) in [("dotted", "[ui]\nstatus_line.type = \"builtin\"\n"), ("inline", "[ui]\nstatus_line = { type = \"builtin\" }\n"),
                      ("top-level", "ui.status_line.type = \"builtin\"\n"), ("two tables", "[ui.status_line]\ntype = \"off\"\n[ui.status_line]\ntype = \"off\"\n"),
                      ("multi-line string", "[ui.status_line]\ntype = \"command\"\ncommand = \"\"\"\nx\"\"\"\n"),
                      ("another copy", "[ui.status_line]\ntype = \"command\"\ncommand = \"'/x/flockbook-statusline' --dir '/other'\"\n")] {
        var threw = false
        do { _ = try on(t) } catch { threw = true }
        check(threw, "grok status line: refused: \(name)")
    }

    // The file: a backup before each write, the mode kept, on and off twice write once each, off gives the bytes back.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hkgsl-\(getpid())-\(UUID().uuidString.prefix(6))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("config.toml"), folder = StatusLineFolder(url: dir.appendingPathComponent("statusline-grok"))
    try Data(builtin.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
    let b1 = try GrokStatusLineSetting.apply(on: true, file: file, command: ours, folder: folder)
    let b2 = try GrokStatusLineSetting.apply(on: true, file: file, command: ours, folder: folder)
    let mode = (try FileManager.default.attributesOfItem(atPath: file.path))[.posixPermissions] as? Int
    check(b1 != nil && (try? String(contentsOf: b1!, encoding: .utf8)) == builtin && b2 == nil && mode == 0o640 && folder.wasOn,
          "grok status line: on: backup first, mode kept, on again writes nothing")
    let b3 = try GrokStatusLineSetting.apply(on: false, file: file, command: ours, folder: folder)
    let b4 = try GrokStatusLineSetting.apply(on: false, file: file, command: ours, folder: folder)
    check(b3 != nil && b4 == nil && (try? String(contentsOf: file, encoding: .utf8)) == builtin && !folder.hasOriginal,
          "grok status line: off: the owner's file back byte for byte, off again writes nothing")

    // The wrapper: Grok's JSON is read like Claude Code's; a built-in original is drawn from it, a command runs.
    let input = Data(#"{"session_id":"01a166c8-5663-7923-8842-d77d57a870d0","cwd":"/w/proj","workspace":{"current_dir":"/w/proj"},"model":{"id":"grok-4.7","display_name":"Grok 4.7"},"context_window":{"used_percentage":12,"context_window_size":256000},"cost":{"total_cost_usd":0.4213},"turn":{"started_at_ms":1000}}"#.utf8)
    let info = ClaudeStatusInfo(json: input)
    check(info?.session == "01a166c8-5663-7923-8842-d77d57a870d0" && info?.model == "Grok 4.7" && info?.contextPercent == 12 && info?.costUSD == 0.4213, "grok status line: Grok's JSON read")
    let line = GrokBuiltinLine.render(input, items: ["cwd", "model", "context", "cost", "turn-timer", "session-name"], now: Date(timeIntervalSince1970: 66))
    check(line == "proj │ Grok 4.7 │ 12% ctx │ $0.42 │ 1m 05s", "grok status line: the built-in items drawn \(line)")
    let cheap = Data(#"{"session_id":"g","model":{"display_name":"Grok 4.7"},"cost":{"total_cost_usd":0.004}}"#.utf8)
    check(GrokBuiltinLine.render(cheap, items: ["cost", "context", "model"], now: Date()) == "Grok 4.7", "grok status line: cost under half a cent and unknown context left out")
    let wdir = dir.appendingPathComponent("w"), wf = StatusLineFolder(url: wdir)
    try wf.saveOriginal(["type": "builtin", "items": ["model", "context"]])
    let r = StatusLineWrapper.run(input: input, dir: wdir, timeout: 5)
    check(String(decoding: r.output, as: UTF8.self) == "Grok 4.7 │ 12% ctx\n" && r.status == 0
          && wf.record(session: "01a166c8-5663-7923-8842-d77d57a870d0")?.lines.map { $0.map(\.text).joined() } == ["Grok 4.7 │ 12% ctx"],
          "grok status line: the wrapper draws a built-in original and saves it \(String(decoding: r.output, as: UTF8.self))")
    try wf.saveOriginal(["type": "none"])
    check(StatusLineWrapper.run(input: input, dir: wdir, timeout: 5).output.isEmpty, "grok status line: none: the wrapper prints nothing")
}
