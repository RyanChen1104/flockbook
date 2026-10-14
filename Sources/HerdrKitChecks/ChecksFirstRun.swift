import Foundation
@testable import HerdrKit

/// First run: what the app finds when herdr is missing, not running, or its socket is closed to this user. Real sockets
/// in a temp folder; nothing talks to a herdr session.
func checksFirstRun() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "fb-firstrun-\(getpid())").path
    try FileManager.default.createDirectory(atPath: dir + "/bin", withIntermediateDirectories: true)
    let emptyBin = dir + "/empty"
    try FileManager.default.createDirectory(atPath: emptyBin, withIntermediateDirectories: true)
    let herdr = dir + "/bin/herdr"
    FileManager.default.createFile(atPath: herdr, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    let home = dir + "/home"   // no ~/.local/bin, no ~/.cargo/bin
    let withHerdr = ["PATH": "/usr/bin:/bin:" + dir + "/bin"], without = ["PATH": emptyBin]
    // The usual install folders may hold a real herdr on this Mac.
    let fallback = ConnectionCheck.findHerdr(environment: ["PATH": emptyBin], home: home)

    /// A Unix socket at `path`: listening, or bound only (connect is refused).
    func socket(_ path: String, listen: Bool) -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in path.utf8.enumerated() { raw[i] = b }; raw[path.utf8.count] = 0 }
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if listen { Darwin.listen(fd, 4) }
        return fd
    }
    func session(_ name: String?, _ path: String) -> HerdrSession { HerdrSession(name: name, socketPath: path) }

    check(ConnectionCheck.findHerdr(environment: withHerdr, home: home) == herdr, "firstrun: herdr found on PATH")
    check(ConnectionCheck.findHerdr(environment: [:], home: home) == fallback, "firstrun: no PATH -> only the usual install folders")

    // No socket.
    let none = dir + "/none.sock"
    check(ConnectionCheck.diagnose(session: session(nil, none), environment: withHerdr, home: home) == .notRunning(command: "herdr"),
          "firstrun: herdr installed, no server -> start it with `herdr`")
    check(ConnectionCheck.diagnose(session: session("work", none), environment: withHerdr, home: home) == .notRunning(command: "herdr --session work"),
          "firstrun: a named session -> `herdr --session work`")
    check(ConnectionCheck.diagnose(session: session(nil, none), environment: without, home: home, usual: [emptyBin]) == .herdrMissing,
          "firstrun: no herdr program, no server -> install herdr")
    check(ConnectionCheck.findHerdr(environment: without, home: home, usual: [dir + "/bin"]) == herdr, "firstrun: herdr found in a usual folder off PATH")

    // A socket nobody listens on (herdr quit without removing it).
    let stale = dir + "/stale.sock"
    let fs = socket(stale, listen: false); defer { close(fs) }
    check(ConnectionCheck.diagnose(session: session(nil, stale), environment: withHerdr, home: home) == .notRunning(command: "herdr"),
          "firstrun: stale socket -> not running")

    // A listening socket this user may not open.
    let shut = dir + "/shut.sock"
    let fc = socket(shut, listen: true); defer { close(fc) }
    chmod(shut, 0)
    check(ConnectionCheck.diagnose(session: session(nil, shut), environment: withHerdr, home: home) == .noPermission(path: shut),
          "firstrun: socket mode 000 -> no permission")

    // A server that listens: no problem.
    let live = dir + "/live.sock"
    let fl = socket(live, listen: true); defer { close(fl) }
    check(ConnectionCheck.diagnose(session: session(nil, live), environment: without, home: home) == nil, "firstrun: listening socket -> nil")

    // A path that is no socket at all.
    let file = dir + "/file.sock"
    FileManager.default.createFile(atPath: file, contents: Data())
    if case .failed = ConnectionCheck.diagnose(session: session(nil, file), environment: withHerdr, home: home) {
        check(true, "firstrun: a plain file -> failed with the reason")
    } else { check(false, "firstrun: a plain file -> failed with the reason") }

    // Every problem says what to do next: a command, a link, or a step in its text.
    let all: [ConnectionProblem] = [.herdrMissing, .notRunning(command: "herdr"), .noPermission(path: shut), .failed(path: file, reason: "Socket operation on non-socket")]
    for p in all {
        check(!p.title.isEmpty && !p.short.isEmpty && (p.command != nil || p.link != nil || p.detail.contains("start it again")),
              "firstrun: \(p.short) -> a next step")
    }
    check(ConnectionProblem.notRunning(command: "herdr --session work").command == "herdr --session work", "firstrun: the command to copy")
    check(ConnectionProblem.herdrMissing.link == ConnectionProblem.herdrSite, "firstrun: install link")
}
