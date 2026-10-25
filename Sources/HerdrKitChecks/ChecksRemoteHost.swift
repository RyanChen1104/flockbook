import Foundation
@testable import HerdrKit

// Remote herdr: SSH destinations, command lines, ssh's options, and files on a host. `Via.local` runs the host side
// with /bin/sh on this Mac, so these need no second machine.
@MainActor func checksRemoteHost() async throws {
    // Destinations ssh could read as an option, or that carry shell characters, are refused.
    // A host agent without a session id: the conversation says to install herdr's integration there.
    let h = try RemoteHost.ssh("user@host")
    check(SessionResolver.hostSetup(kind: "claude", sessionId: nil, remote: h) == "herdr integration install claude", "remote host: claude without a session id needs herdr's integration")
    check(SessionResolver.hostSetup(kind: "codex", sessionId: nil, remote: h) == "herdr integration install codex", "remote host: codex the same")
    check(SessionResolver.hostSetup(kind: "claude", sessionId: "s1", remote: h) == nil, "remote host: a session id needs nothing")
    check(SessionResolver.hostSetup(kind: "claude", sessionId: nil, remote: nil) == nil, "remote host: this Mac finds the log itself")
    check(SessionResolver.hostSetup(kind: "grok", sessionId: nil, remote: h) == "herdr integration install grok", "remote host: grok the same (herdr's grok hook reports the session)")
    check(SessionResolver.hostSetup(kind: "pi", sessionId: nil, remote: h) == nil, "remote host: an agent the app reads no log for gets no command")
    for bad in ["", "-oProxyCommand=touch /tmp/x", "-p", "host name", "a;b", "a$(b)", "a`b`", "a\nb", "a/b", "a'b", "a\"b", "ä@host"] {
        check(RemoteHost.destinationProblem(bad) != nil, "remote host: destination \(bad.debugDescription) refused")
        check((try? RemoteHost.ssh(bad)) == nil, "remote host: ssh(\(bad.debugDescription)) throws")
    }
    for good in ["host", "user@host", "user@host.example.com", "dev-box_2", "user@[2001:db8::1]", "fe80::1%en0", "h:2222"] {
        check(RemoteHost.destinationProblem(good) == nil, "remote host: destination \(good) accepted")
    }

    // ssh: options first, then "--", the destination and the one command line. Host keys checked, no prompts,
    // no forwarding.
    do {
        let h = try RemoteHost.ssh("user@host")
        let a = h.argv("echo hi", controlDir: "/tmp/fb")
        check(a.first == "/usr/bin/ssh", "remote host: runs /usr/bin/ssh")
        check(Array(a.suffix(3).prefix(2)) == ["--", "user@host"], "remote host: -- then destination (\(a.suffix(3)))")
        check(a.last?.hasPrefix("exec /bin/sh -c ") == true, "remote host: the command runs in /bin/sh, not the login shell (\(a.last ?? ""))")
        let opts = a.joined(separator: " ")
        for o in ["BatchMode=yes", "StrictHostKeyChecking=yes", "ForwardAgent=no", "ClearAllForwardings=yes", "ControlPath=/tmp/fb/cm-%C", "PermitLocalCommand=no"] {
            check(opts.contains(o), "remote host: ssh option \(o)")
        }
        check(!opts.contains("StrictHostKeyChecking=no") && !opts.contains("accept-new"), "remote host: host keys are never accepted blindly")
    }

    // Words that broke quoting that matched characters, not bytes: a quote, backslash or "!" with a combining mark
    // after it is one Character; control bytes (1 to 4 were once a private code); "%" (a printf format); non-ASCII.
    // The two probes would run a command if a quote came undone.
    let oddWords = ["it's", "a'\u{301}b", "x'\u{301}$(echo INJECTED >&2)'\u{301}", "x\u{3};echo PWNED >&2;\u{3}", "!\u{338}", "\\\u{301}",
                    "100%", "%s%n", "é 中文 🐑", "new\nline", "back\\slash", "!bang", "`id`", "$HOME"]
        + (1...31).map { String(UnicodeScalar(UInt8($0))) }
    // A program started as sshd starts the login shell: no shell of ours in between. posix_spawn, not Process:
    // Process passes arguments in decomposed form ("é" c3 a9 arrives as 65 cc 81), which would change the words.
    func direct(_ argv: [String]) throws -> RemoteHost.Result {
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
        guard pipe(&out) == 0, pipe(&err) == 0 else { throw HerdrError.socket("pipe failed") }
        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fa, out[1], 1)
        posix_spawn_file_actions_adddup2(&fa, err[1], 2)
        for fd in out + err { posix_spawn_file_actions_addclose(&fa, fd) }
        let cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &fa, nil, cargs, environ)
        posix_spawn_file_actions_destroy(&fa)
        close(out[1]); close(err[1])
        let oh = FileHandle(fileDescriptor: out[0], closeOnDealloc: true), eh = FileHandle(fileDescriptor: err[0], closeOnDealloc: true)
        guard rc == 0 else { throw HerdrError.socket("posix_spawn \(argv[0]) failed: \(rc)") }
        let o = oh.readDataToEndOfFile(), e = eh.readDataToEndOfFile()   // small outputs: stderr fits its pipe
        var st: Int32 = 0
        waitpid(pid, &st, 0)
        return RemoteHost.Result(status: (st & 0x7f) == 0 ? (st >> 8) & 0xff : -1, stdout: o, stderr: String(decoding: e, as: UTF8.self))
    }

    // sshd hands the command line to the host user's login shell ($SHELL -c). Whatever that shell is (sh, bash, zsh,
    // dash, ksh, csh, tcsh, fish), the script must do exactly what `/bin/sh -c script` does, byte for byte.
    do {
        let script = """
            x='it'\\''s'; printf '%s|' "$x" "$(echo sub)" 'back\\slash' "a\\\\c" '!bang' "trail\\\\"
            for i in 1 2; do
              printf '%s;' "$i"
            done
            printf 'two\nlines\\n' | wc -l | tr -d ' '
            printf '\\0%s' \(oddWords.map(RemoteHost.quote).joined(separator: " "))
            """
        let word = try RemoteHost.ssh("user@host").argv(script, controlDir: "/tmp/fb").last ?? ""
        check(!word.contains("\n"), "remote host: the login shell gets one line (csh refuses a newline in quotes)")
        check(!word.utf8.contains(UInt8(ascii: "!")), "remote host: no \"!\" for csh's history to expand")
        check(!word.utf8.contains { $0 < 0x20 || $0 >= 0x7f }, "remote host: the login shell's word is printable ASCII")
        let want = try direct(["/bin/sh", "-c", script])   // the script itself, not wrapped
        check(want.ok && want.stderr.isEmpty, "remote host: the sample script runs in sh (\(want.stderr))")
        let words = want.stdout.split(separator: 0, omittingEmptySubsequences: false).map { Data($0) }   // NUL before each odd word
        check(words.suffix(oddWords.count) == oddWords.map { Data($0.utf8) }, "remote host: odd words come back byte for byte from sh")
        for sh in [["/bin/sh", "-c"], ["/bin/bash", "--norc", "-c"], ["/bin/zsh", "-f", "-c"], ["/bin/dash", "-c"], ["/bin/ksh", "-c"],
                   ["/bin/csh", "-f", "-c"], ["/bin/tcsh", "-f", "-c"]]
        where FileManager.default.isExecutableFile(atPath: sh[0]) {
            let got = try direct(sh + [word])
            check(got.ok && got.stdout == want.stdout && got.stderr.isEmpty,
                  "remote host: \(sh[0]) as the login shell does what sh -c script does (\(got.status) \(got.stderr.prefix(200)))")
        }
        // The host's /bin/sh may be dash (Debian, Ubuntu), ksh or bash: the same word with each as the inner sh.
        let inner = "exec /bin/sh -c "
        check(word.hasPrefix(inner), "remote host: the word starts with \(inner)")
        for sh in ["/bin/dash", "/bin/ksh", "/bin/bash"] {
            guard FileManager.default.isExecutableFile(atPath: sh) else { print("skip: \(sh) as the inner sh (not installed)"); continue }
            let got = try direct(["/bin/sh", "-c", "exec \(sh) -c " + word.dropFirst(inner.count)])
            check(got.ok && got.stdout == want.stdout && got.stderr.isEmpty,
                  "remote host: \(sh) as the inner sh does what sh -c script does (\(got.status) \(got.stderr.prefix(200)))")
        }
        // fish (often not installed here): inside '…' it reads \\ and \' as escapes, so the word must have neither.
        // Read byte by byte (not by Character: a combining mark would hide a quote).
        let bs = Array(word.utf8), q = UInt8(ascii: "'"), bsl = UInt8(ascii: "\\")
        var i = 0, inQuote = false, fishSafe = true
        while i < bs.count {
            let c = bs[i], next: UInt8? = i + 1 < bs.count ? bs[i + 1] : nil
            if inQuote {
                if c == q { inQuote = false } else if c == bsl && (next == bsl || next == q) { fishSafe = false }
            } else if c == bsl {
                i += 1   // sh and fish both take the next byte as is
            } else if c == q {
                inQuote = true
            }
            i += 1
        }
        check(fishSafe && !inQuote, "remote host: fish reads the quoted word as sh does")
    }

    // Quoting: any word survives /bin/sh unchanged.
    do {
        let words = ["plain", "two words", "it's", "$HOME", "`id`", "a\"b", "back\\slash", "new\nline", "*", ""] + oddWords
        let bytes = words.map { Data($0.utf8) }
        let cmd = "printf '%s\\0' " + words.map(RemoteHost.quote).joined(separator: " ")
        func split(_ d: Data) -> [Data] { d.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { Data($0) } }
        let d = try direct(["/bin/sh", "-c", cmd])
        check(d.ok && d.stderr.isEmpty && split(d.stdout) == bytes, "remote host: quoted words come back byte for byte from sh (\(d.stderr.prefix(200)))")
        // through run: the word Process passes is plain ASCII, so non-ASCII words keep their bytes (not decomposed)
        let r = try await RemoteHost(via: .local).run(cmd)
        check(r.ok && r.stderr.isEmpty && split(r.stdout) == bytes, "remote host: quoted words come back byte for byte through run (\(r.stderr.prefix(200)))")
        // The quote is escaped even when a combining mark follows it (one Character, two scalars).
        check(Array(RemoteHost.quote("a'\u{301}b").utf8) == Array("'a'\\''\u{301}b'".utf8), "remote host: a quote before a combining mark is escaped")
    }

    // A command with a NUL is refused: argv cannot hold one, and ksh93 as /bin/sh cuts the command there.
    do {
        var why = ""
        do { _ = try RemoteHost(via: .local).process("printf '%s' 'a\u{0}b'") } catch { why = "\(error)" }
        check(why.contains("NUL"), "remote host: a command with a NUL is refused (\(why))")
        var why2 = ""
        do { _ = try await RemoteHost(via: .local).run("echo '\u{0}'") } catch { why2 = "\(error)" }
        check(why2.contains("NUL"), "remote host: run refuses a NUL too (\(why2))")
    }

    // herdrCommand: no herdr on the host → exit 127 with the marker.
    do {
        let h = RemoteHost(via: .local)
        let r = try await h.run("PATH=/nonexistent HOME=/nonexistent; " + RemoteHost.herdrCommand(session: "s", ["--version"]).replacingOccurrences(of: "/opt/homebrew/bin/herdr /usr/local/bin/herdr", with: ""))
        check(r.status == 127 && r.stderr.contains(RemoteHost.herdrMissingMarker), "remote host: no herdr → 127 + marker (\(r.status) \(r.stderr))")
        check(RemoteHost.herdrCommand(session: nil, ["x"]).contains("\"$HOME/.local/share/mise/shims/herdr\""), "remote host: herdr installed with mise is found")
        check(RemoteHost.herdrCommand(session: "a b", ["x"]).hasSuffix("exec \"$h\" '--session' 'a b' 'x'"), "remote host: herdr args quoted")
    }

    // run: timeout kills; stdin reaches the command; status and stderr come back.
    do {
        let h = RemoteHost(via: .local)
        let slow = try await h.run("sleep 5", timeout: .milliseconds(200))
        check(slow.status == -1, "remote host: timeout gives -1 (\(slow.status))")
        // A command that never reads its stdin: the timer runs while the input is written (a full pipe must not block).
        let t0 = Date()
        let deaf = try await h.run("sleep 5", input: Data(count: 1 << 20), timeout: .milliseconds(200))
        check(deaf.status == -1 && Date().timeIntervalSince(t0) < 3, "remote host: timeout holds while stdin is unread (\(deaf.status), \(Date().timeIntervalSince(t0)) s)")
        // A child that keeps the output pipes open after the kill must not hold run forever.
        let t1 = Date()
        let orphan = try await h.run("sleep 8 & sleep 5", timeout: .milliseconds(200))
        check(orphan.status == -1 && Date().timeIntervalSince(t1) < 5, "remote host: a kept-open pipe does not hold run after a timeout (\(Date().timeIntervalSince(t1)) s)")
        let cat = try await h.run("cat", input: Data("abc".utf8))
        check(cat.ok && cat.stdout == Data("abc".utf8), "remote host: stdin reaches the command")
        let bad = try await h.run("echo oops >&2; exit 3")
        check(bad.status == 3 && bad.stderr == "oops\n", "remote host: status and stderr")
    }

    // Runtime folder: ours, mode 700.
    do {
        let d = try RemoteHost.ensureRuntimeDir()
        var st = stat()
        check(lstat(d, &st) == 0 && st.st_uid == getuid() && st.st_mode & 0o077 == 0, "remote host: runtime folder is private")
        check((d + "/api-0123456789abcdef-99999999.sock").utf8.count < 104, "remote host: relay socket path fits sun_path")
    }

    // Sessions: --remote and --remote-local; a refused destination falls back to local with a note.
    do {
        let s = HerdrSession.fromLaunch(arguments: ["app", "--remote", "user@host", "--session", "t"], environment: [:])
        check(s.remote == (try? RemoteHost.ssh("user@host")) && s.name == "t" && s.socketPath.hasPrefix(RemoteHost.runtimeDir + "/api-"),
              "remote host: --remote + --session")
        let e = HerdrSession.fromLaunch(arguments: ["app"], environment: ["HERDR_DESK_REMOTE": "box"])
        check(e.remote == (try? RemoteHost.ssh("box")) && e.name == nil, "remote host: HERDR_DESK_REMOTE")
        let l = HerdrSession.fromLaunch(arguments: ["app", "--remote-local", "--session", "t"], environment: [:])
        check(l.remote == RemoteHost(via: .local), "remote host: --remote-local")
        let bad = HerdrSession.fromLaunch(arguments: ["app", "--remote", "-oProxyCommand=x"], environment: [:])
        check(bad.remote == nil, "remote host: a refused destination is not used")
        check(HerdrSession.remote(RemoteHost(via: .local), name: "a").socketPath != HerdrSession.remote(RemoteHost(via: .local), name: "b").socketPath,
              "remote host: one relay socket per session")
        // Two app runs on the same host and session each own their relay socket (stopping one leaves the other).
        check(HerdrSession.remote(RemoteHost(via: .local), name: "a").socketPath.hasSuffix("-\(getpid()).sock"), "remote host: relay socket is per process")
        // Saved per-session state (pulled texts) is kept apart per machine; local sessions keep their old key.
        let ka = HerdrSession.remote(try RemoteHost.ssh("a@box"), name: "s").stateKey, kb = HerdrSession.remote(try RemoteHost.ssh("b@box"), name: "s").stateKey
        check(ka != kb && ka != "s" && ka != nil, "remote host: state key differs per host (\(ka ?? "nil") \(kb ?? "nil"))")
        check(HerdrSession.named("s").stateKey == "s" && HerdrSession.default().stateKey == nil, "remote host: local state keys unchanged")
        check(HerdrSession.remote(try RemoteHost.ssh("a@box"), name: nil).stateKey != nil, "remote host: a host's default session has its own key")
    }

    // Relay sockets of app runs that ended are removed; live ones and other files stay.
    do {
        let dir = try RemoteHost.ensureRuntimeDir() + "/chk-sweep-\(getpid())"
        mkdir(dir, 0o700)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run(); ended.waitUntilExit()
        let dead = ended.processIdentifier
        let stale = dir + "/api-0123456789abcdef-\(dead).sock", mine = dir + "/api-0123456789abcdef-\(getpid()).sock"
        let notSocket = dir + "/api-fedcba9876543210-\(dead).sock", other = dir + "/cm-\(dead).sock"
        for p in [stale, mine, other] { close(try RemoteBridge.listen(at: p)) }
        FileManager.default.createFile(atPath: notSocket, contents: Data("x".utf8))
        RemoteBridge.removeStaleSockets(in: dir)
        let fm = FileManager.default
        check(!fm.fileExists(atPath: stale), "remote host: a dead run's relay socket is removed")
        check(fm.fileExists(atPath: mine) && fm.fileExists(atPath: notSocket) && fm.fileExists(atPath: other),
              "remote host: live sockets, plain files and ssh's sockets stay")
    }

    // Files on the host.
    do {
        let f = RemoteFiles(host: RemoteHost(via: .local))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fb-remotefiles-\(UUID().uuidString.prefix(8))").path
        let path = dir + "/sub dir/it's.jsonl"
        let bytes = Data((0..<300).map { UInt8($0 % 256) })
        try await f.write(bytes, to: path)
        check(await f.size(path) == 300, "remote files: size")
        check(await f.read(path, offset: 0, count: 300) == bytes, "remote files: whole file, binary-safe")
        check(await f.read(path, offset: 290, count: 50) == bytes.suffix(10), "remote files: read past the end is short")
        check(await f.read(path, offset: 100, count: 5) == bytes[100..<105], "remote files: a range")
        check(await f.read(dir + "/missing", offset: 0, count: 5) == nil, "remote files: missing → nil")
        check(await f.size(dir + "/missing") == nil, "remote files: missing size → nil")
        check(await f.isFile(path), "remote files: isFile")
        check(await f.list(dir + "/sub dir") == ["it's.jsonl"], "remote files: list")
        check(await f.find(under: dir, nameSuffix: "s.jsonl") == path, "remote files: find by suffix")
        check(await f.find(under: dir, nameSuffix: "*.jsonl") == nil, "remote files: suffix is literal")
        var st = stat()
        check(lstat(path, &st) == 0 && st.st_mode & 0o777 == 0o600, "remote files: written mode 600")
        check(await f.home() == NSHomeDirectory(), "remote files: home")
        await f.remove(path)
        check(await f.size(path) == nil, "remote files: removed")
        try? FileManager.default.removeItem(atPath: dir)
    }
}
