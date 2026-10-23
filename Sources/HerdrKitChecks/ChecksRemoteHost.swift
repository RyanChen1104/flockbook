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
        check(Array(a.suffix(3)) == ["--", "user@host", "echo hi"], "remote host: -- then destination then command (\(a.suffix(3)))")
        let opts = a.joined(separator: " ")
        for o in ["BatchMode=yes", "StrictHostKeyChecking=yes", "ForwardAgent=no", "ClearAllForwardings=yes", "ControlPath=/tmp/fb/cm-%C", "PermitLocalCommand=no"] {
            check(opts.contains(o), "remote host: ssh option \(o)")
        }
        check(!opts.contains("StrictHostKeyChecking=no") && !opts.contains("accept-new"), "remote host: host keys are never accepted blindly")
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
        check(RemoteHost.herdrCommand(session: "a b", ["x"]).hasSuffix("exec \"$h\" '--session' 'a b' 'x'"), "remote host: herdr args quoted")
    }

    // run: timeout kills; stdin reaches the command; status and stderr come back.
    do {
        let h = RemoteHost(via: .local)
        let slow = try await h.run("sleep 5", timeout: .milliseconds(200))
        check(slow.status == -1, "remote host: timeout gives -1 (\(slow.status))")
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
        check((d + "/api-0123456789abcdef.sock").utf8.count < 104, "remote host: relay socket path fits sun_path")
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
