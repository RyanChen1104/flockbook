import Foundation
@testable import HerdrKit

/// The `herdr` program for terminals: found where herdr's installer puts it even when the app has Finder's short PATH,
/// and a terminal that cannot start says why instead of retrying forever on a blank view. Fake programs only.
func checksHerdrPath() async throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appending(path: "fb-herdrpath-\(getpid())").path
    defer { try? fm.removeItem(atPath: dir) }
    let home = dir + "/home", local = home + "/.local/bin", cargo = home + "/.cargo/bin", custom = dir + "/custom"
    for d in [local, cargo, custom, dir + "/empty"] { try fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
    func program(_ path: String) { fm.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]) }
    program(local + "/herdr"); program(cargo + "/herdr"); program(custom + "/herdr")
    let finder = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]   // a Finder or Dock launch

    // Search order: HERDR_BIN, PATH, ~/.local/bin (herdr's installer), Homebrew, /usr/local/bin, ~/.cargo/bin.
    check(ConnectionCheck.findHerdr(environment: finder, home: home) == local + "/herdr",
          "herdrpath: Finder's PATH -> ~/.local/bin/herdr (herdr's installer), before Homebrew")
    check(ConnectionCheck.findHerdr(environment: finder.merging(["HERDR_BIN": custom + "/herdr"]) { $1 }, home: home) == custom + "/herdr",
          "herdrpath: HERDR_BIN wins")
    check(ConnectionCheck.findHerdr(environment: finder.merging(["HERDR_BIN": dir + "/nothing"]) { $1 }, home: home) == local + "/herdr",
          "herdrpath: a HERDR_BIN that is not a program is skipped")
    check(ConnectionCheck.findHerdr(environment: ["PATH": custom], home: home) == custom + "/herdr", "herdrpath: PATH before the usual folders")
    check(ConnectionCheck.usualFolders(home: home) == [local, "/opt/homebrew/bin", "/usr/local/bin", cargo], "herdrpath: the usual folders, in order")
    check(ConnectionCheck.findHerdr(environment: ["PATH": dir + "/empty"], home: home, usual: [dir + "/empty"]) == nil, "herdrpath: nowhere -> nil")
    check(ConnectionCheck.notFound == "herdr not found on PATH or in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, ~/.cargo/bin.",
          "herdrpath: the not-found reason names the folders")

    // Only a program counts: a folder named herdr or a file without the x bit does not stop the search; a symlink does count.
    let folder = dir + "/folder", plain = dir + "/plain", link = dir + "/link", dirLink = dir + "/dirlink"
    for d in [folder + "/herdr", plain, link, dirLink] { try fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
    fm.createFile(atPath: plain + "/herdr", contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o644])
    try fm.createSymbolicLink(atPath: link + "/herdr", withDestinationPath: custom + "/herdr")
    try fm.createSymbolicLink(atPath: dirLink + "/herdr", withDestinationPath: folder + "/herdr")
    check(ConnectionCheck.findHerdr(environment: ["PATH": folder], home: home) == local + "/herdr", "herdrpath: a folder named herdr on PATH is skipped")
    check(ConnectionCheck.findHerdr(environment: ["PATH": folder, "HERDR_BIN": folder + "/herdr"], home: home) == local + "/herdr",
          "herdrpath: HERDR_BIN naming a folder is skipped")
    check(ConnectionCheck.findHerdr(environment: ["PATH": plain], home: home) == local + "/herdr", "herdrpath: a herdr file without the x bit is skipped")
    check(ConnectionCheck.findHerdr(environment: ["PATH": plain, "HERDR_BIN": plain + "/herdr"], home: home) == local + "/herdr",
          "herdrpath: HERDR_BIN naming a file without the x bit is skipped")
    check(ConnectionCheck.findHerdr(environment: ["PATH": link], home: home) == link + "/herdr", "herdrpath: a symlink to the program counts")
    check(ConnectionCheck.findHerdr(environment: ["PATH": dirLink], home: home) == local + "/herdr", "herdrpath: a symlink to a folder is skipped")
    check(ConnectionCheck.programWarning(environment: ["PATH": folder], home: dir + "/nohome", usual: [folder]) != nil,
          "herdrpath: only a folder named herdr -> the warning")

    // herdr not running: the command to start it uses HERDR_BIN's full path (often not on the Terminal's PATH), quoted for the shell.
    let spaced = dir + "/my tools"
    try fm.createDirectory(atPath: spaced, withIntermediateDirectories: true)
    program(spaced + "/herdr")
    let noServer = dir + "/none.sock"
    check(ConnectionCheck.diagnose(session: HerdrSession(name: nil, socketPath: noServer), environment: ["PATH": dir + "/empty", "HERDR_BIN": custom + "/herdr"], home: home)
          == .notRunning(command: custom + "/herdr"), "herdrpath: not running, HERDR_BIN -> its full path")
    check(ConnectionCheck.diagnose(session: HerdrSession(name: "work", socketPath: noServer), environment: ["PATH": dir + "/empty", "HERDR_BIN": spaced + "/herdr"], home: home)
          == .notRunning(command: "'\(spaced)/herdr' --session work"), "herdrpath: a HERDR_BIN with a space is quoted")
    check(ConnectionCheck.shellQuoted("/a/it's") == "'/a/it'\\''s'" && ConnectionCheck.shellQuoted("/usr/bin/herdr") == "/usr/bin/herdr",
          "herdrpath: shell quoting")
    check(ConnectionCheck.diagnose(session: HerdrSession(name: nil, socketPath: noServer), environment: ["PATH": dir + "/empty", "HERDR_BIN": folder + "/herdr"], home: home)
          == .notRunning(command: "herdr"), "herdrpath: HERDR_BIN not a program -> plain `herdr`")

    // The program a terminal runs: herdr's full path (no `/usr/bin/env herdr`), PATH with the usual folders for herdr itself.
    check(TerminalSession.launcher(session: .default(), environment: finder, home: home) == [local + "/herdr"], "herdrpath: terminal runs ~/.local/bin/herdr")
    check(TerminalSession.launcher(session: .named("work"), environment: finder, home: home) == [local + "/herdr", "--session", "work"],
          "herdrpath: a named session keeps --session")
    check(TerminalSession.childPath(environment: finder, home: home).split(separator: ":").map(String.init).contains(local),
          "herdrpath: the terminal's PATH has ~/.local/bin")

    // A terminal that cannot start: one final reason, no endless retries.
    final class EBox: @unchecked Sendable { let l = NSLock(); var v: [TerminalEvent] = []
        func add(_ x: TerminalEvent) { l.withLock { v.append(x) } }
        var all: [TerminalEvent] { l.withLock { v } } }
    func run(_ ts: TerminalSession, _ sec: Double) async -> (events: [TerminalEvent], ended: Bool) {
        let box = EBox(), ended = Locked(false)
        let reader = Task { for await e in ts.events { box.add(e) }; ended.set(true) }
        ts.start()
        let t = Date()
        while Date().timeIntervalSince(t) < sec, !ended.get() { try? await Task.sleep(nanoseconds: 20_000_000) }
        ts.stop(); reader.cancel()
        return (box.all, ended.get())
    }
    func failed(_ e: [TerminalEvent]) -> String? { e.lazy.compactMap { if case .failed(let r) = $0 { return r } else { return nil } }.first }
    func retries(_ e: [TerminalEvent]) -> Int { e.filter { if case .reconnecting = $0 { return true } else { return false } }.count }

    let gone = dir + "/gone.sh"   // what `env` does when herdr is not on its PATH
    try "#!/bin/sh\necho 'env: herdr: No such file or directory' >&2\nexit 127\n".write(toFile: gone, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gone)
    let r127 = await run(TerminalSession(terminalId: "term_x", session: .default(), launcher: [gone]), 3)
    check(r127.ended && retries(r127.events) == 0 && failed(r127.events)?.contains("No such file or directory") == true,
          "herdrpath: exit 127 before any frame -> failed with herdr's words, no retry (\(retries(r127.events)) retries)")

    // herdr's last words come in pieces and without a newline: all of them are the reason, every time.
    let pieces = dir + "/pieces.sh"
    try "#!/bin/sh\ni=0\nwhile [ $i -lt 40 ]; do echo \"warn $i\" >&2; i=$((i+1)); done\nprintf 'env: herdr: ' >&2\nsleep 0.05\nprintf 'No such file or directory' >&2\nexit 127\n"
        .write(toFile: pieces, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pieces)
    var whole = 0
    for _ in 0..<8 {
        let r = await run(TerminalSession(terminalId: "term_x", session: .default(), launcher: [pieces]), 3)
        if r.ended, failed(r.events) == "env: herdr: No such file or directory" { whole += 1 }
    }
    check(whole == 8, "herdrpath: exit 127, stderr in pieces with no last newline -> the whole last line, 8 of 8 (\(whole))")

    // The real start: the found program with --session and the terminal's arguments, PATH with ~/.local/bin.
    let argsLog = dir + "/args", spy = dir + "/spy.sh"
    try "#!/bin/sh\necho \"$*\" > '\(argsLog)'\necho \"$PATH\" >> '\(argsLog)'\nexit 127\n".write(toFile: spy, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: spy)
    _ = await run(TerminalSession(terminalId: "term_x", session: .named("work"), find: { spy }), 3)
    let spied = ((try? String(contentsOfFile: argsLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    check(spied.first?.hasPrefix("--session work terminal session control term_x") == true, "herdrpath: started as `herdr --session work terminal session control …` (\(spied.first ?? "not started"))")
    check(spied.count == 2 && spied[1].split(separator: ":").contains(Substring(NSHomeDirectory() + "/.local/bin")), "herdrpath: herdr's PATH has ~/.local/bin")

    let none = await run(TerminalSession(terminalId: "term_x", session: .default(), find: { nil }), 3)
    check(none.ended && failed(none.events) == ConnectionCheck.notFound, "herdrpath: no herdr program -> failed: not found")

    let crash = dir + "/crash.sh"   // starts, then dies without a frame: retried, and each try's stderr is passed on
    try "#!/bin/sh\necho 'socket gone' >&2\nexit 1\n".write(toFile: crash, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: crash)
    let r1 = await run(TerminalSession(terminalId: "term_x", session: .default(), launcher: [crash]), 1.5)
    check(!r1.ended && retries(r1.events) >= 1 && failed(r1.events) == nil, "herdrpath: exit 1 -> still retried (herdr restarting)")

    // First run: herdr answers on its socket, but the program is not where the app looks: say so.
    check(ConnectionCheck.programWarning(environment: ["PATH": dir + "/empty"], home: dir + "/nohome", usual: [dir + "/empty"])
          == "herdr program not found: terminals can't start", "herdrpath: connected, no program -> a warning")
    check(ConnectionCheck.programWarning(environment: finder, home: home) == nil, "herdrpath: connected, program found -> no warning")
}
