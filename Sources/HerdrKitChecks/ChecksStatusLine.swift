import Foundation
@testable import HerdrKit

// Claude Code's status line in Flockbook (opt-in): Claude Code runs our wrapper as its statusLine command; the wrapper
// saves the JSON Claude Code gives it, runs the owner's own command with the same input, prints that command's output
// unchanged and saves it too. The app shows the saved line under the composer and on the phone. Flockbook itself never
// runs the owner's command.
@MainActor func checksStatusLine() async throws {
    let esc = "\u{1B}"
    func tmp(_ name: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("fb-statusline-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // ANSI SGR text -> styled runs, one list per line.
    do {
        let l = ANSIText.lines("\(esc)[0m\(esc)[38;2;136;136;136mabc\(esc)[0m \(esc)[1;32mok\(esc)[0m")
        check(l == [[StyledRun("abc", fg: "#888888"), StyledRun(" "), StyledRun("ok", fg: ANSIText.basic[2], bold: true)]],
              "status line ansi: truecolor, reset, bold + basic green (\(l))")
        check(ANSIText.lines("\(esc)[38;5;196mred\(esc)[39m plain") == [[StyledRun("red", fg: "#ff0000"), StyledRun(" plain")]],
              "status line ansi: 256-colour cube, 39 resets the colour")
        check(ANSIText.lines("\(esc)[38;5;244mg") == [[StyledRun("g", fg: "#808080")]], "status line ansi: 256-colour grey ramp")
        check(ANSIText.lines("\(esc)[91mb\(esc)[38;5;9mc") == [[StyledRun("bc", fg: ANSIText.basic[9])]], "status line ansi: bright colours; same style merges")
        check(ANSIText.lines("\(esc)[48;2;1;2;3;2;3;4mx\(esc)[22;23;24;49my") == [[StyledRun("x", bg: "#010203", dim: true, italic: true, underline: true), StyledRun("y")]],
              "status line ansi: background, dim, italic, underline and their resets")
        check(ANSIText.lines("one\r\ntwo\n") == [[StyledRun("one")], [StyledRun("two")]], "status line ansi: lines; a last newline adds none")
        check(ANSIText.lines("\(esc)]8;;https://example.com\(esc)\\PR #1\(esc)]8;;\(esc)\\ done") == [[StyledRun("PR #1 done")]],
              "status line ansi: an OSC 8 link keeps its text")
        check(ANSIText.lines("a\(esc)[2Kb\(esc)[?25lc\u{07}d\u{00}e\tf") == [[StyledRun("abcde f")]], "status line ansi: other escapes and control characters go; a tab is a space")
        check(ANSIText.lines("\(esc)[1mstill bold\nnext") == [[StyledRun("still bold", bold: true)], [StyledRun("next", bold: true)]],
              "status line ansi: a style goes on over a newline, as in a terminal")
        check(ANSIText.lines("x\(esc)[") == [[StyledRun("x")]] && ANSIText.lines("\(esc)[38;5;999my\(esc)[38;2;300mz") == [[StyledRun("yz")]],
              "status line ansi: cut or out-of-range sequences are dropped")
        check(ANSIText.lines(String(repeating: "a\n", count: 20)).count == ANSIText.maxLines, "status line ansi: at most \(ANSIText.maxLines) lines")
        let long = ANSIText.lines(String(repeating: "é", count: 5_000))
        check(long.first?.reduce(0) { $0 + $1.text.count } == ANSIText.maxColumns, "status line ansi: a line is cut at \(ANSIText.maxColumns) characters")
        check(ANSIText.lines("") == [] && ANSIText.lines("\n\n") == [], "status line ansi: nothing to show: no lines")
        check(ANSIText.plain([[StyledRun("a", bold: true), StyledRun("b")], [StyledRun("c")]]) == "ab\nc", "status line ansi: plain text")
    }

    // The JSON Claude Code gives the command.
    let input = Data(#"""
    {"session_id":"5ad83985-b099-4ce9-82e6-85dd73af9b4a","transcript_path":"/x/y.jsonl","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},
     "cost":{"total_cost_usd":0.4213,"total_duration_ms":45000},"effort":{"level":"high"},
     "context_window":{"context_window_size":1000000,"used_percentage":37.4,"total_input_tokens":374000}}
    """#.utf8)
    do {
        let i = ClaudeStatusInfo(json: input)
        check(i?.session == "5ad83985-b099-4ce9-82e6-85dd73af9b4a" && i?.model == "Opus 5.5" && i?.effort == "high"
              && i?.costUSD == 0.4213 && i?.contextPercent == 37 && i?.contextSize == 1_000_000,
              "status line info: session, model, effort, cost, context (\(String(describing: i)))")
        check(i?.summary == "Opus 5.5 · high · ctx 37% · $0.42", "status line info: the summary line (\(i?.summary ?? "nil"))")
        let bare = ClaudeStatusInfo(json: Data(#"{"session_id":"abc","model":{"display_name":"Haiku"}}"#.utf8))
        check(bare?.costUSD == nil && bare?.contextPercent == nil && bare?.summary == "Haiku", "status line info: missing fields stay out")
        check(ClaudeStatusInfo(json: Data(#"{"session_id":"../../etc"}"#.utf8)) == nil && ClaudeStatusInfo(json: Data(#"{"model":{}}"#.utf8)) == nil
              && ClaudeStatusInfo(json: Data("not json".utf8)) == nil && ClaudeStatusInfo(json: Data(#"{"session_id":"a/b"}"#.utf8)) == nil,
              "status line info: no usable session id: nil")
    }

    // The row's tags (appendix C): model, effort, context with its bar (orange from 80%), the cost marked as an estimate;
    // a field Claude Code did not send has no tag. The orange reads on the tag in light and dark (text: 4.5:1).
    do {
        let tags = ClaudeStatusInfo(json: input)?.tags ?? []
        check(tags.map(\.kind) == [.model, .effort, .context, .cost] && tags.map(\.text) == ["Opus 5.5", "high", "ctx 37%", "$0.42 est."]
              && tags.count == 4 && tags[2].percent == 37 && !tags[2].warn,
              "status tags: model, effort, context, cost (\(tags.map(\.text)))")
        check(tags.map(\.spoken) == ["Model Opus 5.5", "Effort high", "Context 37% used", "Session cost about $0.42, an estimate"],
              "status tags: spoken labels (\(tags.map(\.spoken)))")
        let hot = ClaudeStatusInfo(json: Data(#"{"session_id":"a","context_window":{"used_percentage":80}}"#.utf8))?.tags ?? []
        let cool = ClaudeStatusInfo(json: Data(#"{"session_id":"a","context_window":{"used_percentage":79.4}}"#.utf8))?.tags ?? []
        check(hot.map(\.kind) == [.context] && hot.first?.warn == true && cool.first?.warn == false,
              "status tags: context from 80% is a warning, under it not; no other tags (\(hot.map(\.text)))")
        check(ClaudeStatusInfo(json: Data(#"{"session_id":"a"}"#.utf8))?.tags == [], "status tags: nothing sent, no tags")
        for dark in [false, true] {
            let r = StatusTag.contrast(StatusTag.warnHex(dark: dark), StatusTag.tagHex(dark: dark))
            check(r >= 4.5, "status tags: the orange on a \(dark ? "dark" : "light") tag reads (\(String(format: "%.2f", r)):1)")
        }
    }

    // One row: the tags that fit, in order; the chevron at the right when one is left out or there is more to open.
    do {
        let w: [CGFloat] = [60, 40, 70, 60]   // 60+6+40+6+70 = 182, +6+60 = 248; the chevron takes 6+20
        func fit(_ available: CGFloat, more: Bool = false) -> StatusTagRow.Fit {
            StatusTagRow.fit(widths: w, chevron: 20, spacing: 6, available: available, more: more)
        }
        check(fit(400) == .init(shown: 4, chevron: false), "status row: all fit, nothing more: no chevron (\(fit(400)))")
        check(fit(248) == .init(shown: 4, chevron: false), "status row: exactly fits (\(fit(248)))")
        check(fit(400, more: true) == .init(shown: 4, chevron: true), "status row: all fit, own lines to open: the chevron (\(fit(400, more: true)))")
        check(fit(247) == .init(shown: 3, chevron: true), "status row: one left out: three and the chevron (\(fit(247)))")
        check(fit(30) == .init(shown: 0, chevron: true), "status row: none fits: the chevron alone (\(fit(30)))")
        check(StatusTagRow.fit(widths: [], chevron: 20, spacing: 6, available: 400, more: true) == .init(shown: 0, chevron: true),
              "status row: no tags, own lines: the chevron")
    }

    // The folder: the wrapper saves, the app reads one session's record.
    do {
        let dir = tmp("folder")
        let f = StatusLineFolder(url: dir)
        let sid = "5ad83985-b099-4ce9-82e6-85dd73af9b4a"
        check(f.record(session: sid) == nil, "status line folder: nothing saved, no record")
        f.save(input: input, output: Data("\(esc)[32mmain\(esc)[0m $0.42".utf8), session: sid)
        let r = f.record(session: sid)
        check(r?.lines == [[StyledRun("main", fg: ANSIText.basic[2]), StyledRun(" $0.42")]] && r?.info?.costUSD == 0.4213,
              "status line folder: the saved line and info come back (\(String(describing: r)))")
        let mode = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("\(sid).out").path))?[.posixPermissions] as? Int
        check(mode == 0o600, "status line folder: files are mode 600 (\(String(mode ?? 0, radix: 8)))")
        f.save(input: input, output: Data(), session: sid)
        check(f.record(session: sid)?.lines == [] && f.record(session: sid)?.isEmpty == false,
              "status line folder: no own line: still shown (the info's tags)")
        check(StatusLineRecord(lines: [], info: ClaudeStatusInfo(json: Data(#"{"session_id":"a"}"#.utf8)), time: Date()).isEmpty,
              "status line folder: no own line and no facts: nothing to show")
        check(f.record(session: "../\(sid)") == nil && f.record(session: "") == nil, "status line folder: a session id that is not a plain name is not read")
        let old = dir.appendingPathComponent("\(sid).out")
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * StatusLineFolder.maxAge)], ofItemAtPath: old.path)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * StatusLineFolder.maxAge)],
                                               ofItemAtPath: dir.appendingPathComponent("\(sid).json").path)
        check(f.record(session: sid) == nil, "status line folder: a record older than a day is not shown")
        f.clean()
        check(!FileManager.default.fileExists(atPath: old.path), "status line folder: clean removes old records")
        try? FileManager.default.removeItem(at: dir)
    }

    // The wrapper: the owner's command with the same input, its output unchanged, both saved; never slower than the limit.
    do {
        let dir = tmp("wrap")
        let sid = "5ad83985-b099-4ce9-82e6-85dd73af9b4a"
        func original(_ command: String?) {
            StatusLineFolder(url: dir).saveOriginal(command.map { ["type": "command", "command": $0, "padding": 1] as [String: Any] })
        }
        original(#"printf 'hi \033[32mok\033[0m'"#)
        var r = StatusLineWrapper.run(input: input, dir: dir, timeout: 5)
        check(r.output == Data("hi \(esc)[32mok\(esc)[0m".utf8) && r.status == 0, "status line wrapper: the owner's output, unchanged (\(String(decoding: r.output, as: UTF8.self)))")
        check(StatusLineFolder(url: dir).record(session: sid)?.lines == [[StyledRun("hi "), StyledRun("ok", fg: ANSIText.basic[2])]], "status line wrapper: saves the input and the output")

        original("cat")
        r = StatusLineWrapper.run(input: input, dir: dir, timeout: 5)
        check(r.output == input, "status line wrapper: the command reads the same input on stdin")
        original(#"echo "$COLUMNS""#)
        r = StatusLineWrapper.run(input: input, dir: dir, timeout: 5, environment: ["COLUMNS": "123", "PATH": "/usr/bin:/bin"])
        check(r.output == Data("123\n".utf8), "status line wrapper: the command gets Claude Code's environment (COLUMNS)")

        original(nil)
        r = StatusLineWrapper.run(input: input, dir: dir, timeout: 5)
        check(r.output.isEmpty && r.status == 0 && StatusLineFolder(url: dir).record(session: sid)?.info?.model == "Opus 5.5",
              "status line wrapper: no own command: prints nothing, still saves the input")

        original("echo partial; exit 3")
        r = StatusLineWrapper.run(input: input, dir: dir, timeout: 5)
        check(r.output == Data("partial\n".utf8) && r.status == 3, "status line wrapper: a failing command: its output and exit status, as without Flockbook")

        let mark = "31.\(Int.random(in: 100_000...999_999))"
        original("echo early; (sleep \(mark)1 &); sleep \(mark)2")
        let t0 = Date()
        r = StatusLineWrapper.run(input: input, dir: dir, timeout: 0.5)
        let took = Date().timeIntervalSince(t0)
        try? await Task.sleep(for: .milliseconds(300))
        let left = Process.runQuietly("/usr/bin/pgrep", ["-f", "sleep \(mark)"])
        check(took < 2 && r.output == Data("early\n".utf8) && r.status != 0, "status line wrapper: a hung command stops at the limit (\(String(format: "%.2f", took)) s), its output so far is printed")
        check(left.isEmpty, "status line wrapper: no process is left behind (\(left))")

        original("echo still")
        let bad = Data(#"{"session_id":"../x"}"#.utf8)
        r = StatusLineWrapper.run(input: bad, dir: dir, timeout: 5)
        check(r.output == Data("still\n".utf8) && !FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("x.json").path),
              "status line wrapper: a bad session id: output unchanged, nothing saved")
        let ro = tmp("ro")
        StatusLineFolder(url: ro).saveOriginal(["type": "command", "command": "echo fine"])
        try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: ro.path)
        r = StatusLineWrapper.run(input: input, dir: ro, timeout: 5)
        check(r.output == Data("fine\n".utf8) && r.status == 0, "status line wrapper: cannot save: output unchanged")
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ro.path)
        check(StatusLineWrapper.run(input: Data(), dir: tmp("none"), timeout: 5).output.isEmpty, "status line wrapper: no folder, no input: prints nothing")
        try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: ro)
    }

    // Claude Code's settings: on puts our command in statusLine and keeps the owner's; off puts the owner's back.
    do {
        let ours = ClaudeStatusLineSetting.command(wrapper: "/Applications/Flockbook.app/Contents/MacOS/flockbook-statusline", dir: "/tmp/sl dir")
        check(ours == "'/Applications/Flockbook.app/Contents/MacOS/flockbook-statusline' --dir '/tmp/sl dir'", "status line setting: our command, quoted (\(ours))")
        let theirs: [String: Any] = ["type": "command", "command": "sh ~/.claude/line.sh", "padding": 2, "refreshInterval": 5]
        var (s, orig) = try ClaudeStatusLineSetting.enabling(["model": "opus", "statusLine": theirs], command: ours)
        let line = s["statusLine"] as? [String: Any]
        check(line?["command"] as? String == ours && line?["type"] as? String == "command" && line?["padding"] as? Int == 2
              && line?["refreshInterval"] as? Int == 5 && s["model"] as? String == "opus",
              "status line setting: on: our command, the owner's padding and refresh kept, other keys kept")
        check((orig?["command"] as? String) == "sh ~/.claude/line.sh", "status line setting: on: the owner's statusLine is kept to put back")
        let twice = try ClaudeStatusLineSetting.enabling(s, command: ours)
        check(NSDictionary(dictionary: twice.settings).isEqual(to: s) && twice.original == nil, "status line setting: on twice = once")
        (s, orig) = try ClaudeStatusLineSetting.enabling(["model": "opus"], command: ours)
        check((s["statusLine"] as? [String: Any])?["command"] as? String == ours && orig == nil, "status line setting: on without a statusLine")
        var threw = false
        do { _ = try ClaudeStatusLineSetting.enabling(["statusLine": "x"], command: ours) } catch { threw = true }
        check(threw, "status line setting: a statusLine that is not an object is left alone")

        let on = try ClaudeStatusLineSetting.enabling(["model": "opus", "statusLine": theirs], command: ours)
        let back = ClaudeStatusLineSetting.disabling(on.settings, command: ours, original: on.original)
        check(NSDictionary(dictionary: back).isEqual(to: ["model": "opus", "statusLine": theirs]), "status line setting: off puts the owner's statusLine back")
        let none = ClaudeStatusLineSetting.disabling(try ClaudeStatusLineSetting.enabling(["model": "opus"], command: ours).settings, command: ours, original: nil)
        check(NSDictionary(dictionary: none).isEqual(to: ["model": "opus"]), "status line setting: off with no own statusLine removes ours")
        let changed: [String: Any] = ["statusLine": ["type": "command", "command": "new.sh"]]
        check(NSDictionary(dictionary: ClaudeStatusLineSetting.disabling(changed, command: ours, original: theirs)).isEqual(to: changed),
              "status line setting: off after the owner changed it: their new one stays")
        check(ClaudeStatusLineSetting.state(on.settings, command: ours, wasOn: true) == .on
              && ClaudeStatusLineSetting.state(["model": "opus"], command: ours, wasOn: false) == .off
              && ClaudeStatusLineSetting.state(changed, command: ours, wasOn: true) == .replaced
              && ClaudeStatusLineSetting.state(changed, command: ours, wasOn: false) == .off,
              "status line setting: on, off, and replaced (on before, another command now, e.g. /statusline)")
    }

    // The settings file: backed up, written atomically, the owner's line kept beside it; off restores the file's line.
    do {
        let home = tmp("home")
        let file = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let before = #"{"model":"opus","statusLine":{"type":"command","command":"sh line.sh","padding":2}}"#
        try Data(before.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let dir = home.appendingPathComponent("support/statusline")
        let folder = StatusLineFolder(url: dir)
        let ours = ClaudeStatusLineSetting.command(wrapper: "/bin/flockbook-statusline", dir: dir.path)
        let backup = try ClaudeStatusLineSetting.apply(on: true, file: file, command: ours, folder: folder)
        let now = try ClaudeSettingsHook.read(file)
        check((now["statusLine"] as? [String: Any])?["command"] as? String == ours && now["model"] as? String == "opus", "status line file: on writes our command")
        check(backup.map { (try? String(contentsOf: $0, encoding: .utf8)) == before } == true, "status line file: on backs the file up first")
        check(folder.original()?["command"] as? String == "sh line.sh" && folder.wasOn, "status line file: the owner's line is kept for the wrapper and for off")
        check((try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int == 0o644, "status line file: the file's mode is kept")
        check(try ClaudeStatusLineSetting.apply(on: true, file: file, command: ours, folder: folder) == nil && folder.original()?["command"] as? String == "sh line.sh",
              "status line file: on twice changes nothing, the owner's line is not lost")
        _ = try ClaudeStatusLineSetting.apply(on: false, file: file, command: ours, folder: folder)
        let after = try ClaudeSettingsHook.read(file)
        check(NSDictionary(dictionary: after).isEqual(to: (try? JSONSerialization.jsonObject(with: Data(before.utf8))) as? [String: Any] ?? [:]) && !folder.wasOn,
              "status line file: off restores the owner's line")
        var refused = false
        do {
            _ = try ClaudeStatusLineSetting.apply(on: true, file: file, command: ours, folder: folder, beforeWrite: {
                try? Data(#"{"model":"sonnet"}"#.utf8).write(to: file)
            })
        } catch { refused = true }
        let meanwhile = try ClaudeSettingsHook.read(file)
        check(refused && meanwhile["model"] as? String == "sonnet" && !folder.wasOn, "status line file: changed meanwhile: nothing written")
        let link = home.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        refused = false
        do { _ = try ClaudeStatusLineSetting.apply(on: true, file: link, command: ours, folder: folder) } catch { refused = true }
        check(refused, "status line file: a linked settings file is refused")
        try? FileManager.default.removeItem(at: home)
    }

    // The hub: a watched Claude pane gets its status line; each change; gone: an empty one clears it.
    do {
        func ws(kind: String = "claude") -> [Workspace] {
            let a = Agent(name: kind, kind: kind, status: .working, sessionId: "s1", title: "Fix the build")
            return [Workspace(id: "w1", label: "web", tabs: [Tab(id: "w1:t1", label: "build", number: 1,
                              panes: [Pane(id: "w1:p1", terminalId: "term_1", cwd: "/work", agent: a)], status: .working)])]
        }
        let devices = MemoryDeviceStore()
        devices.add(token: "tok", device: HubDevice(id: "d", name: "Phone", level: .read))
        func session(_ b: FakeHubBackend) async -> HubSession {
            let s = HubSession(backend: b, devices: devices)
            _ = await s.receive(Data(#"{"v":1,"type":"hello","id":"h","token":"tok","client":"test","clientVersion":"1"}"#.utf8))
            return s
        }
        func line(_ ms: [HubMessage]) -> HubStatusLine? { ms.lazy.compactMap { if case .statusLine(let l) = $0 { l } else { nil } }.first }
        let watch = Data(#"{"v":1,"type":"watch","id":"c1","pane":"w1:p1"}"#.utf8)
        let b = FakeHubBackend(workspaces: ws())
        let info = ClaudeStatusInfo(json: input)
        b.statusLines["s1"] = StatusLineRecord(lines: [[StyledRun("main", fg: "#00ff00")]], info: info, time: Date())
        let s = await session(b)
        let l = line(await s.receive(watch))
        check(l?.pane == "w1:p1" && l?.lines == [[StyledRun("main", fg: "#00ff00")]] && l?.costUSD == 0.4213 && l?.contextPercent == 37 && l?.model == "Opus 5.5"
              && l?.effort == "high" && l?.time != nil,
              "hub status line: watch pushes the line, cost, context, model, effort and time (\(String(describing: l)))")
        check(line(await s.tick()) == nil, "hub status line: no change, no push")
        b.statusLines["s1"] = StatusLineRecord(lines: [[StyledRun("dev")]], info: info, time: Date())
        check(line(await s.tick())?.lines == [[StyledRun("dev")]], "hub status line: a change is pushed")
        b.statusLines["s1"] = StatusLineRecord(lines: [], info: info, time: Date())
        let bare = line(await s.tick())
        check(bare?.lines == [] && bare?.model == "Opus 5.5" && bare?.isEmpty == false, "hub status line: no own line: the facts alone, not the summary as a line")
        b.statusLines["s1"] = nil
        check(line(await s.tick())?.isEmpty == true, "hub status line: gone: an empty push clears it")
        let codex = FakeHubBackend(workspaces: ws(kind: "codex"))
        codex.statusLines["s1"] = StatusLineRecord(lines: [[StyledRun("x")]], info: nil, time: Date())
        check(line(await (await session(codex)).receive(watch)) == nil, "hub status line: only Claude panes")
        let none = FakeHubBackend(workspaces: ws())
        check(line(await (await session(none)).receive(watch)) == nil, "hub status line: none, no push on watch")
        let msg = HubStatusLine(pane: "w1:p1", record: b.statusLines["s1"] ?? StatusLineRecord(lines: [[StyledRun("a", fg: "#123456", bold: true)]], info: info, time: Date()))
        check(try Hub.decodeHub(try Hub.encode(HubMessage.statusLine(msg))) == .statusLine(msg), "hub status line: round-trips")
        let json = String(decoding: try Hub.encode(HubMessage.statusLine(HubStatusLine(pane: "w1:p1", record: StatusLineRecord(lines: [[StyledRun("a", fg: "#123456", bold: true)]], info: nil, time: Date())))), as: UTF8.self)
        check(json.contains(#""lines":[[{"#) && json.contains(##""fg":"#123456""##) && !json.contains("costUSD\":null"), "hub status line: compact JSON (\(json))")
    }
}

extension Process {
    /// stdout of a short command, trimmed ("" when it fails).
    static func runQuietly(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
