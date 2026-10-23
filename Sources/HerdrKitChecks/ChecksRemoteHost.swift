import Foundation
@testable import HerdrKit

// Remote herdr: SSH destinations, command lines, ssh's options, and files on a host. `Via.local` runs the host side
// with /bin/sh on this Mac, so these need no second machine.
@MainActor func checksRemoteHost() async throws {
    // Destinations ssh could read as an option, or that carry shell characters, are refused.
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

    // sshd hands the command line to the host user's login shell ($SHELL -c). Whatever that shell is (csh, tcsh, zsh,
    // fish), the POSIX script must run in /bin/sh as is: multi-line, quotes, backslashes, "!", $(…), loops.
    do {
        let script = """
            x='it'\\''s'; printf '%s|' "$x" "$(echo sub)" 'back\\slash' "a\\\\c" '!bang' "trail\\\\"
            for i in 1 2; do
              printf '%s;' "$i"
            done
            printf 'two\nlines\\n' | wc -l | tr -d ' '
            """
        let word = try RemoteHost.ssh("user@host").argv(script, controlDir: "/tmp/fb").last ?? ""
        check(!word.contains("\n"), "remote host: the login shell gets one line (csh refuses a newline in quotes)")
        check(!word.contains("!"), "remote host: no \"!\" for csh's history to expand")
        let want = try await RemoteHost(via: .local).run(script)
        check(want.ok, "remote host: the sample script runs in sh (\(want.stderr))")
        for sh in [["/bin/sh", "-c"], ["/bin/csh", "-f", "-c"], ["/bin/tcsh", "-f", "-c"], ["/bin/zsh", "-f", "-c"], ["/bin/bash", "--norc", "-c"]]
        where FileManager.default.isExecutableFile(atPath: sh[0]) {
            // started directly, as sshd would: through `run` it would be wrapped a second time
            let p = Process(), out = Pipe(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: sh[0]); p.arguments = Array(sh.dropFirst()) + [word]
            p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
            try p.run()
            let gotOut = out.fileHandleForReading.readDataToEndOfFile(), gotErr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            let got = RemoteHost.Result(status: p.terminationStatus, stdout: gotOut, stderr: gotErr)
            check(got.ok && got.stdout == want.stdout, "remote host: \(sh[0]) as the login shell runs the script as sh does (\(String(decoding: got.stdout, as: UTF8.self)) \(got.stderr))")
        }
        // fish (often not installed here): inside '…' it reads \\ and \' as escapes, so the word must have neither.
        let cs = Array(word)
        var i = 0, inQuote = false, fishSafe = true
        while i < cs.count {
            let c = cs[i], next: Character? = i + 1 < cs.count ? cs[i + 1] : nil
            if inQuote {
                if c == "'" { inQuote = false } else if c == "\\" && (next == "\\" || next == "'") { fishSafe = false }
            } else if c == "\\" {
                i += 1   // sh and fish both take the next character as is
            } else if c == "'" {
                inQuote = true
            }
            i += 1
        }
        check(fishSafe && !inQuote, "remote host: fish reads the quoted word as sh does (\(word))")
    }

    // Quoting: any word survives /bin/sh unchanged.
    do {
        let words = ["plain", "two words", "it's", "$HOME", "`id`", "a\"b", "back\\slash", "new\nline", "*", ""]
        let h = RemoteHost(via: .local)
        let r = try await h.run("printf '%s\\0' " + words.map(RemoteHost.quote).joined(separator: " "))
        let got = r.stdout.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
        check(r.ok && got == words, "remote host: quoted words come back as is (\(got))")
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
