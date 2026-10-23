import Foundation
@testable import HerdrKit

// Remote herdr (Terminal): embedded terminals on a host run `herdr terminal session …` through `RemoteHost.process`, with
// the same JSON lines on stdio. `Via.local` plus a fake herdr on PATH stands in for the host: no ssh, no real herdr.
@MainActor func checksRemoteTerminal() async throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appending(path: "fb-remote-term-\(getpid())").path
    defer { try? fm.removeItem(atPath: dir) }
    let bin = dir + "/bin"
    try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)

    // The herdr words after the program: mode, id, --takeover, size.
    check(TerminalSession.arguments(terminalId: "term_a", mode: .observe, cols: nil, rows: nil) == ["terminal", "session", "observe", "term_a"],
          "remote term: observe arguments")
    check(TerminalSession.arguments(terminalId: "term_a", mode: .control(takeover: false), cols: 80, rows: nil)
          == ["terminal", "session", "control", "term_a", "--cols", "80"], "remote term: control arguments with cols")
    check(TerminalSession.arguments(terminalId: "w1:p2", mode: .control(takeover: true), cols: 100, rows: 30)
          == ["terminal", "session", "control", "w1:p2", "--takeover", "--cols", "100", "--rows", "30"], "remote term: takeover arguments with size")
    check(TerminalSession.remoteCommand(session: "a b", ["terminal", "session", "observe", "term_a"])
          == RemoteHost.herdrCommand(session: "a b", ["terminal", "session", "observe", "term_a"]), "remote term: default command is herdrCommand")

    // Terminal ids: herdr's own (`term_a`, `w1:p2`); nothing ssh, sh or herdr could read as an option or a second word.
    for good in ["term_a", "w1:p2", "term-3.x"] { check(TerminalSession.idProblem(good) == nil, "remote term: id \(good) accepted") }
    for bad in ["", "-x", "--takeover", "a b", "a;b", "a$(b)", "a'b", "a\nb", String(repeating: "a", count: 300)] {
        check(TerminalSession.idProblem(bad) != nil, "remote term: id \(bad.debugDescription.prefix(20)) refused")
    }

    // ssh and the host side, in plain words. Auth and host keys are final; a host that does not answer is retried.
    let host = "user@box"
    let missing = TerminalSession.remoteProblem(status: 127, stderr: RemoteHost.herdrMissingMarker + "\n", host: host)
    check(missing?.reason == "herdr is not installed on user@box." && missing?.final == true, "remote term: 127 + marker -> not installed (\(missing?.reason ?? "nil"))")
    let hostKey = TerminalSession.remoteProblem(status: 255, stderr: "No ED25519 host key is known for box and you have requested strict checking.\nHost key verification failed.\n", host: host)
    check(hostKey?.final == true && hostKey?.reason.contains("host key") == true && hostKey?.reason.contains("ssh user@box") == true,
          "remote term: host key -> final, says to run ssh once (\(hostKey?.reason ?? "nil"))")
    let denied = TerminalSession.remoteProblem(status: 255, stderr: "user@box: Permission denied (publickey).\n", host: host)
    check(denied?.final == true && denied?.reason.contains("log in") == true, "remote term: permission denied -> final (\(denied?.reason ?? "nil"))")
    let refused = TerminalSession.remoteProblem(status: 255, stderr: "ssh: connect to host box port 22: Connection refused\n", host: host)
    check(refused?.final == false && refused?.reason.hasPrefix("Can't reach user@box") == true, "remote term: refused -> retried (\(refused?.reason ?? "nil"))")
    let dns = TerminalSession.remoteProblem(status: 255, stderr: "ssh: Could not resolve hostname box: nodename nor servname provided\n", host: host)
    check(dns?.final == false && dns?.reason.contains("user@box") == true, "remote term: unknown host name -> retried (\(dns?.reason ?? "nil"))")
    check(TerminalSession.remoteProblem(status: 1, stderr: "socket gone\n", host: host) == nil, "remote term: herdr's own exit 1 -> not an ssh problem")
    check(TerminalSession.remoteProblem(status: 127, stderr: "something else\n", host: host) == nil, "remote term: 127 without the marker -> not classified")

    // Event helpers (the same as the local terminal checks).
    final class EBox: @unchecked Sendable { let l = NSLock(); var v: [TerminalEvent] = []
        func add(_ x: TerminalEvent) { l.withLock { v.append(x) } }
        var all: [TerminalEvent] { l.withLock { v } }
        var frames: [TerminalFrame] { all.compactMap { if case .frame(let f) = $0 { return f } else { return nil } } } }
    func until(_ sec: Double, _ ok: () -> Bool) async -> Bool {
        let t = Date()
        while Date().timeIntervalSince(t) < sec { if ok() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return ok()
    }
    func failed(_ e: [TerminalEvent]) -> String? { e.lazy.compactMap { if case .failed(let r) = $0 { return r } else { return nil } }.first }
    func retries(_ e: [TerminalEvent]) -> Int { e.filter { if case .reconnecting = $0 { return true } else { return false } }.count }

    // A fake herdr on the host's PATH: writes its words (NUL-separated), prints one frame, then copies stdin to a file.
    let argsFile = dir + "/args", inputFile = dir + "/input"
    let frameLine = #"{"type":"terminal.frame","seq":1,"full":true,"width":80,"height":24,"bytes":"b2sNCg=="}"#
    try """
    #!/bin/sh
    for a in "$@"; do printf '%s\\0' "$a"; done > '\(argsFile)'
    echo '\(frameLine)'
    exec cat > '\(inputFile)'
    """.write(toFile: bin + "/herdr", atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/herdr")
    let onPath: TerminalSession.RemoteCommand = { s, a in "PATH=\(RemoteHost.quote(bin)):\"$PATH\"; " + RemoteHost.herdrCommand(session: s, a) }
    let local = RemoteHost(via: .local)
    func words() -> [String] {
        guard let d = fm.contents(atPath: argsFile) else { return [] }
        return d.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
    }

    // Odd session names reach herdr as one word each, through /bin/sh, and nothing in them runs.
    let pwned = dir + "/pwned"
    let cases: [(String?, TerminalSession.Mode, Int?, Int?)] = [
        ("it's $(touch '\(pwned)') `touch '\(pwned)'` \"q\" \\", .control(takeover: true), 100, 30),
        ("--help", .observe, nil, nil),
        (nil, .control(takeover: false), 80, nil),
        ("名字 *", .control(takeover: false), nil, 24),
    ]
    for (name, mode, cols, rows) in cases {
        try? fm.removeItem(atPath: argsFile); try? fm.removeItem(atPath: inputFile)
        let finds = Locked(0)
        let ts = TerminalSession(terminalId: "w1:p2", session: .remote(local, name: name), mode: mode, cols: cols, rows: rows,
                                 find: { finds.update { $0 += 1 }; return nil }, remoteCommand: onPath)
        let box = EBox()
        let reader = Task { for await e in ts.events { box.add(e) } }
        ts.start()
        let framed = await until(5) { !box.frames.isEmpty }
        let want = (name.map { ["--session", $0] } ?? []) + TerminalSession.arguments(terminalId: "w1:p2", mode: mode, cols: cols, rows: rows)
        let got = words()
        check(framed && got == want, "remote term: \(name.map { String($0.prefix(12)) } ?? "default") \(mode) words via sh (\(got))")
        check(box.frames.first?.width == 80 && box.frames.first?.bytes == Data("ok\r\n".utf8), "remote term: frame from the host's herdr")
        check(finds.get() == 0, "remote term: no local herdr lookup for a remote session")
        if case .control = mode {
            check(ts.send(text: "hi"), "remote term: input written to the host process")
            let typed = await until(3) { ((try? String(contentsOfFile: inputFile, encoding: .utf8)) ?? "").contains(#""type":"terminal.input""#) }
            check(typed, "remote term: input reaches the host's herdr stdin")
        }
        ts.stop(); reader.cancel()
    }
    check(!fm.fileExists(atPath: pwned), "remote term: nothing in a session name runs on the host")

    // No herdr on the host: one final reason in plain words, no retries.
    do {
        let none: TerminalSession.RemoteCommand = { s, a in
            "PATH=/nonexistent HOME=/nonexistent; " + RemoteHost.herdrCommand(session: s, a)
                .replacingOccurrences(of: "/opt/homebrew/bin/herdr /usr/local/bin/herdr", with: "")
        }
        let ts = TerminalSession(terminalId: "term_a", session: .remote(local, name: "s"), remoteCommand: none)
        let box = EBox(), ended = Locked(false)
        let reader = Task { for await e in ts.events { box.add(e) }; ended.set(true) }
        ts.start()
        _ = await until(5) { ended.get() }
        check(ended.get() && failed(box.all) == "herdr is not installed on \(local.label)." && retries(box.all) == 0,
              "remote term: no herdr on the host -> failed, not installed (\(failed(box.all) ?? "not failed"), \(retries(box.all)) retries)")
        ts.stop(); reader.cancel()
    }

    // A bad terminal id never reaches the host.
    do {
        try? fm.removeItem(atPath: argsFile)
        let ts = TerminalSession(terminalId: "-x; touch '\(pwned)'", session: .remote(local, name: "s"), remoteCommand: onPath)
        let box = EBox(), ended = Locked(false)
        let reader = Task { for await e in ts.events { box.add(e) }; ended.set(true) }
        ts.start()
        _ = await until(3) { ended.get() }
        check(ended.get() && failed(box.all) != nil && !fm.fileExists(atPath: argsFile) && !fm.fileExists(atPath: pwned),
              "remote term: bad terminal id -> failed, nothing started (\(failed(box.all) ?? "not failed"))")
        reader.cancel()
    }

    // ssh fails before any frame: a readable notice, and the run is retried (backoff unchanged).
    do {
        let unreachable: TerminalSession.RemoteCommand = { _, _ in "echo 'ssh: connect to host box port 22: Connection refused' >&2; exit 255" }
        let ts = TerminalSession(terminalId: "term_a", session: .remote(local, name: nil), remoteCommand: unreachable)
        let box = EBox()
        let reader = Task { for await e in ts.events { box.add(e) } }
        ts.start()
        _ = await until(3) { retries(box.all) >= 1 }
        let notices = box.all.compactMap { if case .notice(let s) = $0 { return s } else { return nil } }
        let lastBeforeRetry: String? = {
            var last: String?
            for e in box.all { if case .notice(let s) = e { last = s }; if case .reconnecting = e { return last } }
            return nil
        }()
        check(retries(box.all) >= 1 && failed(box.all) == nil && lastBeforeRetry?.hasPrefix("Can't reach \(local.label)") == true,
              "remote term: unreachable -> readable notice, retried (\(lastBeforeRetry ?? notices.last ?? "none"))")
        ts.stop(); reader.cancel()
    }

    // HerdrClient.observe on a remote session: frames from the host's herdr.
    do {
        try? fm.removeItem(atPath: argsFile)
        let client = HerdrClient(session: .remote(local, name: "s"))
        let got = Locked<[TerminalFrame]>([])
        let reader = Task { do { for try await f in client.observe(terminalId: "term_a", remoteCommand: onPath) { got.update { $0.append(f) } } } catch {} }
        _ = await until(5) { !got.get().isEmpty }
        check(got.get().first?.bytes == Data("ok\r\n".utf8) && words() == ["--session", "s", "terminal", "session", "observe", "term_a"],
              "remote term: observe stream from the host (\(words()))")
        reader.cancel()
        let none: TerminalSession.RemoteCommand = { s, a in
            "PATH=/nonexistent HOME=/nonexistent; " + RemoteHost.herdrCommand(session: s, a)
                .replacingOccurrences(of: "/opt/homebrew/bin/herdr /usr/local/bin/herdr", with: "")
        }
        let why = Locked<String?>(nil)
        let r2 = Task { do { for try await _ in client.observe(terminalId: "term_a", remoteCommand: none) {} } catch { why.set("\(error)") } }
        _ = await until(5) { why.get() != nil }
        check(why.get()?.contains("herdr is not installed") == true, "remote term: observe, no herdr on the host -> error says so (\(why.get() ?? "none"))")
        r2.cancel()
    }
}
