import Foundation
@testable import HerdrKit

// Remote herdr (Hooks): the Claude question hook and the Claude Code status line on the host. `Via.local` with a temp
// folder as the host's home: the same sh command lines, no second machine, nothing in the real ~/.claude.
@MainActor func checksRemoteHooks() async throws {
    let fm = FileManager.default
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rhooks-\(getpid())-\(UUID().uuidString.prefix(6))", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    let host = RemoteHost(via: .local)
    let files = RemoteFiles(host: host, timeout: .seconds(20))
    let paths = RemoteHookPaths(home: tmp.appendingPathComponent("home dir").path)
    func mode(_ p: String) -> Int? { (try? fm.attributesOfItem(atPath: p))?[.posixPermissions] as? Int }
    func json(_ p: String) -> [String: Any]? { (try? Data(contentsOf: URL(fileURLWithPath: p))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }

    // Paths: all under the host's home; the wrapper keeps the name Claude Code's settings code knows.
    check(paths.settingsFile == paths.home + "/.claude/settings.json", "remote hooks: settings file in the host's ~/.claude")
    check(paths.hookScript.hasPrefix(paths.home + "/.config/flockbook/") && paths.hookRecords.hasPrefix(paths.home + "/.config/flockbook/"),
          "remote hooks: hook files in the host's ~/.config/flockbook")
    check(paths.statusWrapper.hasSuffix("/" + ClaudeStatusLineSetting.wrapperName), "remote hooks: the wrapper is named flockbook-statusline")
    check((await RemoteHookPaths.load(files))?.home.hasPrefix("/") == true, "remote hooks: load finds the host's home")

    // MARK: framing (one command reads several small files)
    do {
        let d = Data("a 100 3\nxyzb 200 0\nc 300 2\n\n\n".utf8)
        let f = RemoteHooks.frames(d)
        check(f.map(\.name) == ["a", "b", "c"] && f.map(\.data) == [Data("xyz".utf8), Data(), Data("\n\n".utf8)]
              && f.map(\.time) == [100, 200, 300].map { Date(timeIntervalSince1970: $0) }, "remote hooks: frames parse (\(f.map(\.name)))")
        check(RemoteHooks.frames(Data("a 1 9\nshort".utf8)).isEmpty, "remote hooks: a cut frame is dropped")
        check(RemoteHooks.frames(Data("a b c\n".utf8)).isEmpty, "remote hooks: a bad header stops the parse")
    }

    // Backups on the host: the first and the newest stay (`ClaudeSettingsHook.keptBackups`), other names are left alone.
    do {
        let b = { (d: Int) in "settings.json.flockbook-statusline-2026010\(d)-000000.bak" }
        let names = Set((1...7).map(b) + ["settings.json.flockbook-20260101-000000.bak", "notes.txt"])
        let gone = RemoteHooks.prunable(names, name: "settings.json", backups: "flockbook-statusline", keeping: b(7))
        check(gone == [b(2), b(3)], "remote hooks: backup pruning keeps the first and the newest (\(gone))")
    }

    // MARK: reads on demand: the last value at once, one read at a time, none again within `every`
    do {
        let reads = Locked(0)
        let poll = RemotePoll<String, Int>(every: 60) { _ in reads.update { $0 += 1; return $0 } }
        check(poll.value("a") == nil, "remote poll: nothing read yet → nil, a read starts")
        var got: Int?
        for _ in 0..<100 where got == nil { try await Task.sleep(for: .milliseconds(20)); got = poll.value("a") }
        check(got == 1 && reads.get() == 1, "remote poll: the read's value; no second read within `every` (\(String(describing: got)), \(reads.get()))")
        poll.reset()
        check(poll.value("a") == nil, "remote poll: reset drops the value")
    }

    // MARK: the question hook
    let hook = RemoteClaudeHook(files: files, paths: paths)
    let mine = #"{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo hi"}]}]},"permissions":{"allow":["Bash(ls:*)"]}}"#
    try fm.createDirectory(atPath: (paths.settingsFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(mine.utf8).write(to: URL(fileURLWithPath: paths.settingsFile))
    try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: paths.settingsFile)
    let before = try JSONSerialization.jsonObject(with: Data(mine.utf8)) as! [String: Any]
    check(try await hook.installed() == false, "remote hook: off before install")

    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let backup = try await hook.install(now: t0)
    check(fm.fileExists(atPath: paths.hookScript) && mode(paths.hookScript) == 0o700, "remote hook install: script written, mode 700 (\(String(describing: mode(paths.hookScript))))")
    check((try? String(contentsOfFile: paths.hookScript, encoding: .utf8)) == ClaudeQuestionHook.script(recordsDir: paths.hookRecords),
          "remote hook install: the script is the hook script for the host folder")
    let after = json(paths.settingsFile) ?? [:]
    check(ClaudeSettingsHook.installed(after, command: hook.command), "remote hook install: our entry is in the host's settings")
    check(NSDictionary(dictionary: ClaudeSettingsHook.removing(after, command: hook.command)).isEqual(to: before), "remote hook install: everything else kept")
    check(mode(paths.settingsFile) == 0o640, "remote hook install: the file's mode kept (\(String(describing: mode(paths.settingsFile))))")
    check(backup.map { (try? Data(contentsOf: URL(fileURLWithPath: $0))) == Data(mine.utf8) } == true
          && backup?.hasPrefix(paths.settingsFile + ".flockbook-") == true, "remote hook install: backup next to it, the old bytes (\(backup ?? "nil"))")
    check(try await hook.installed() == true, "remote hook: on after install")
    check(try await hook.install(now: t0) == nil, "remote hook install twice: nothing written")

    // The script, run as Claude Code runs it, writes a record the app reads back through RemoteFiles.
    let payload = #"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","session_id":"sess-1","tool_use_id":"toolu_01R","tool_input":{"questions":[{"question":"Pick one","header":"Pick","multiSelect":false,"options":[{"label":"A","description":"a"},{"label":"B","description":"b"}]}]}}"#
    let ran = try await host.run(hook.command, input: Data(payload.utf8))
    check(ran.ok && ran.stdout.isEmpty, "remote hook script: exit 0, no output")
    let recs = await hook.records(now: Date()) ?? []
    check(recs.map(\.request.toolUseId) == ["toolu_01R"] && recs.first?.sessionId == "sess-1", "remote hook: the record reads back (\(recs.map(\.request.toolUseId)))")
    // An old record and a stray temp file go; another file name is never read.
    let old = paths.hookRecords + "/1.1.json"
    try Data(payload.utf8).write(to: URL(fileURLWithPath: old))
    try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86400)], ofItemAtPath: old)
    try Data(payload.utf8).write(to: URL(fileURLWithPath: paths.hookRecords + "/x y.json"))
    let recs2 = await hook.records(now: Date())
    check(!fm.fileExists(atPath: old) && recs2?.count == 1, "remote hook: records over a day old are removed, odd names skipped (\(String(describing: recs2?.count)))")

    // Uninstall: only our entry leaves.
    try await hook.uninstall(now: t0.addingTimeInterval(1))
    check(NSDictionary(dictionary: json(paths.settingsFile) ?? [:]).isEqual(to: before), "remote hook uninstall: only our entry leaves")
    check(try await hook.installed() == false, "remote hook: off after uninstall")

    // A linked settings file is refused; so is one that is not a JSON object.
    do {
        let other = RemoteHookPaths(home: tmp.appendingPathComponent("linked").path)
        try fm.createDirectory(atPath: (other.settingsFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: other.settingsFile, withDestinationPath: paths.settingsFile)
        let h = RemoteClaudeHook(files: files, paths: other)
        var refused = false
        do { try await h.install(now: t0) } catch { refused = true }
        check(refused && NSDictionary(dictionary: json(paths.settingsFile) ?? [:]).isEqual(to: before), "remote hook: a linked settings file is refused")
        let bad = RemoteHookPaths(home: tmp.appendingPathComponent("bad").path)
        try fm.createDirectory(atPath: (bad.settingsFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("[1,2]".utf8).write(to: URL(fileURLWithPath: bad.settingsFile))
        refused = false
        do { try await RemoteClaudeHook(files: files, paths: bad).install(now: t0) } catch { refused = true }
        check(refused && (try? String(contentsOfFile: bad.settingsFile, encoding: .utf8)) == "[1,2]", "remote hook: a settings file that is not an object is left alone")
        // No records folder: an empty list (nil is kept for a host that does not answer).
        check(await RemoteClaudeHook(files: files, paths: RemoteHookPaths(home: "/nonexistent-\(getpid())")).records() == [], "remote hook: no records folder → no records")
    }
    // No settings file yet: made, no backup.
    do {
        let fresh = RemoteHookPaths(home: tmp.appendingPathComponent("fresh").path)
        let b = try await RemoteClaudeHook(files: files, paths: fresh).install(now: t0)
        check(b == nil && ClaudeSettingsHook.installed(json(fresh.settingsFile) ?? [:], command: RemoteClaudeHook(files: files, paths: fresh).command),
              "remote hook: no settings file → made with our entry, no backup")
    }

    // MARK: the status line wrapper (POSIX sh)
    let sl = RemoteStatusLine(files: files, paths: paths)
    let seen = tmp.appendingPathComponent("seen").path
    let ownLine = "printf '\\033[1mown\\033[0m line\\n'; cat > \(RemoteHost.quote(seen)); exit 3"
    var withLine = before
    withLine["statusLine"] = ["type": "command", "command": ownLine, "padding": 1] as [String: Any]
    try JSONSerialization.data(withJSONObject: withLine).write(to: URL(fileURLWithPath: paths.settingsFile))
    check(try await sl.state() == .off, "remote status line: off at first")
    _ = try await sl.apply(on: true, now: t0)
    check(try await sl.state() == .on, "remote status line: on after apply(on:)")
    check(fm.isExecutableFile(atPath: paths.statusWrapper) && mode(paths.statusWrapper) == 0o700, "remote status line: wrapper written, mode 700")
    let line = (json(paths.settingsFile)?["statusLine"] as? [String: Any]) ?? [:]
    check(line["command"] as? String == sl.command && line["padding"] as? Int == 1, "remote status line: ours in place, padding kept (\(line))")
    check(await sl.ownCommand() == ownLine, "remote status line: the owner's command is kept on the host")

    let input = Data(#"{"session_id":"sess-7","model":{"display_name":"Opus"},"workspace":{"current_dir":"/x"},"context_window":{"used_percentage":12}}"#.utf8) + Data([0x0a])
    let w = try await host.run(sl.command, input: input)
    let expected = Data("\u{1b}[1mown\u{1b}[0m line\n".utf8)
    check(w.status == 3 && w.stdout == expected, "remote status line wrapper: the owner's output unchanged, their status (\(w.status), \(String(decoding: w.stdout, as: UTF8.self).debugDescription))")
    check((try? Data(contentsOf: URL(fileURLWithPath: seen))) == input, "remote status line wrapper: the owner's command gets the same input")
    check((try? Data(contentsOf: URL(fileURLWithPath: paths.statusDir + "/sess-7.json"))) == input
          && (try? Data(contentsOf: URL(fileURLWithPath: paths.statusDir + "/sess-7.out"))) == expected, "remote status line wrapper: input and output saved")
    let rec = await sl.record(session: "sess-7", now: Date())
    check(rec.map { ANSIText.plain($0.lines) } == "own line" && rec?.info?.session == "sess-7" && rec?.info?.contextPercent == 12,
          "remote status line: the record reads back through RemoteFiles (\(rec.map { ANSIText.plain($0.lines) } ?? "nil"))")
    let odd = await sl.record(session: "../x", now: Date()), unknown = await sl.record(session: "none", now: Date())
    check(odd == nil && unknown == nil, "remote status line: odd or unknown session: none")

    // A run under the wrapper's own guard runs nothing.
    let guarded = try await host.run("FLOCKBOOK_STATUSLINE=1 " + sl.command, input: input)
    check(guarded.ok && guarded.stdout.isEmpty, "remote status line wrapper: guard set → nothing runs")
    // Over the limit: stopped, output so far printed, status 124, the saved output stays.
    do {
        let dir = tmp.appendingPathComponent("slow").path
        let script = tmp.appendingPathComponent("slow-wrapper").path
        try Data(RemoteHooks.statusLineScript(timeout: 1).utf8).write(to: URL(fileURLWithPath: script))
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data("printf part; sleep 5; printf more".utf8).write(to: URL(fileURLWithPath: dir + "/.original-command"))
        try Data("old".utf8).write(to: URL(fileURLWithPath: dir + "/sess-7.out"))
        let start = Date()
        let r = try await host.run("/bin/sh " + RemoteHost.commandLine([script, "--dir", dir]), input: input)
        check(r.status == 124 && r.stdout == Data("part".utf8) && Date().timeIntervalSince(start) < 4,
              "remote status line wrapper: stopped after the limit (\(r.status), \(String(decoding: r.stdout, as: UTF8.self)))")
        check((try? String(contentsOfFile: dir + "/sess-7.out", encoding: .utf8)) == "old", "remote status line wrapper: a stopped run keeps the last output")
        // No own command: prints nothing, exit 0, empty output saved.
        try Data().write(to: URL(fileURLWithPath: dir + "/.original-command"))
        let none = try await host.run("/bin/sh " + RemoteHost.commandLine([script, "--dir", dir]), input: input)
        check(none.ok && none.stdout.isEmpty && (try? Data(contentsOf: URL(fileURLWithPath: dir + "/sess-7.out"))) == Data(),
              "remote status line wrapper: no own command → nothing printed, exit 0")
        // A folder it cannot write: the owner's command still runs and prints.
        try Data("printf ok".utf8).write(to: URL(fileURLWithPath: dir + "/.original-command"))
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir)
        let ro = try await host.run("/bin/sh " + RemoteHost.commandLine([script, "--dir", dir]), input: input)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        check(ro.ok && ro.stdout == Data("ok".utf8), "remote status line wrapper: unwritable folder → the command still runs (\(ro.status))")
    }

    // The owner sets another line: replaced. Off puts theirs back, padding kept, our note gone.
    _ = try await sl.apply(on: false, now: t0.addingTimeInterval(1))
    let back = (json(paths.settingsFile)?["statusLine"] as? [String: Any]) ?? [:]
    check(back["command"] as? String == ownLine && back["padding"] as? Int == 1, "remote status line off: the owner's line is back (\(back))")
    check(!fm.fileExists(atPath: paths.statusDir + "/.original") && !fm.fileExists(atPath: paths.statusDir + "/.original-command"), "remote status line off: the kept line is gone")
    check(try await sl.state() == .off, "remote status line: off after apply(on: false)")
    _ = try await sl.apply(on: true, now: t0.addingTimeInterval(2))
    var replaced = json(paths.settingsFile) ?? [:]
    replaced["statusLine"] = ["type": "command", "command": "echo new"]
    try JSONSerialization.data(withJSONObject: replaced).write(to: URL(fileURLWithPath: paths.settingsFile))
    check(try await sl.state() == .replaced, "remote status line: another line set since → replaced")
    // No line of the owner's: on, then off removes ours.
    do {
        let p2 = RemoteHookPaths(home: tmp.appendingPathComponent("noline").path)
        let s2 = RemoteStatusLine(files: files, paths: p2)
        _ = try await s2.apply(on: true, now: t0)
        check(await s2.ownCommand() == nil, "remote status line: no own line → none kept")
        _ = try await s2.apply(on: false, now: t0)
        check(json(p2.settingsFile)?["statusLine"] == nil, "remote status line: off with no own line removes ours")
    }
}
