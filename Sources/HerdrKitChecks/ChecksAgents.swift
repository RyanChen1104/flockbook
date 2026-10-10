import Foundation
@testable import HerdrKit

// Other agents (pi, Cursor) and the session fallback.

// pi: tree of entries (follow the newest branch), tool calls as chips with results, thinking hidden, errors as status
@MainActor func checksPi() async throws {
    do {
        let pl = String(decoding: fixture("pi.jsonl"), as: UTF8.self).split(separator: "\n").map(String.init)
        let before = SessionLog.parse(lines: Array(pl.prefix(14)))
        check(describe(before) == ["user:List the files.", "asst:Looking.", "chips:Ran a command|Read a file|Edited a file", "asst:Done with a.txt.",
                                   "user:Say something wrong.", "status"], "pi: items before the branch \(describe(before))")
        check(before.last.map { if case .status(let s) = $0.kind { return s == "Error: Rate limited." }; return false } == true, "pi: error stop as status")
        let items = SessionLog.parse(lines: pl)
        check(describe(items) == ["user:List the files.", "asst:Looking.", "chips:Ran a command|Read a file|Edited a file", "asst:Done with a.txt.",
                                  "user:Run pwd yourself.", "chips:Ran a command", "status", "status", "asst:Building.", "perm:make"],
              "pi: newest branch only, edited turn dropped \(describe(items))")
        func chips(_ i: Int) -> [ToolChip] { if case .toolChips(let c) = items[i].kind { return c }; return [] }
        let calls = chips(2).flatMap(\.calls)
        check(calls.map(\.toolName) == ["Bash", "Read", "Edit"] && calls.map(\.output) == ["a.txt", "hello", "no match"] && calls.map(\.isError) == [false, false, true]
              && calls[1].summary == "/tmp/demo/a.txt", "pi: tool calls with results and errors")
        check(chips(5).first?.calls.first?.output == "/tmp/demo" && chips(5).first?.calls.first?.summary == "pwd", "pi: user ! command as a chip")
        check(!items.contains { if case .assistantText(let t) = $0.kind { return t.contains("Hidden") }; return false }, "pi: thinking hidden")
        check(items.map(\.id) == SessionLog.parse(lines: pl).map(\.id) && items[0].id == "u1-0", "pi: stable ids from entry ids")
        var p = ConversationParser()
        for l in pl { p.feed(line: l) }
        check(p.hasOpenToolUse && p.items().map(\.id) == items.map(\.id), "pi: incremental feed = batch, open tool call")
        let dir = NSTemporaryDirectory() + "pi-\(UUID().uuidString).jsonl"
        try? Data(pl.joined(separator: "\n").utf8).write(to: URL(fileURLWithPath: dir))
        check(SessionLog.locate(agent: "pi", sessionId: dir, dir: "/nonexistent")?.path == dir
              && SessionLog.locate(agent: "pi", sessionId: dir + ".x", dir: "/nonexistent") == nil
              && SessionLog.locate(agent: "claude", sessionId: "/etc/passwd", dir: "/nonexistent") == nil, "pi: path sessions resolve directly")
        try? FileManager.default.removeItem(atPath: dir)
    }
}

// Cursor agent transcripts: <user_query> prompts, tool calls as chips (no results in the file), turn_ended errors
@MainActor func checksCursor() async throws {
    do {
        let cl = String(decoding: fixture("cursor.jsonl"), as: UTF8.self).split(separator: "\n").map(String.init)
        let items = SessionLog.parse(lines: cl)
        check(describe(items) == ["user:List the files.", "asst:Looking.", "chips:Ran a command|Read a file|Edited a file", "asst:Done.",
                                  "user:What is this?", "chips:Used a connector", "status", "user:Plain prompt.", "status"], "cursor: items \(describe(items))")
        check(items[0].timestamp == ISO8601DateFormatter().date(from: "2026-09-12T08:09:00Z")
              && items[4].timestamp == ISO8601DateFormatter().date(from: "2026-09-12T06:00:00Z"), "cursor: <timestamp> with UTC offset")
        var p = ConversationParser()
        var off: UInt64 = 0
        for l in cl { p.feed(line: l, offset: off); off += UInt64(l.utf8.count + 1) }
        check(!p.hasOpenToolUse && !p.items().contains { if case .permissionRequest = $0.kind { return true }; return false }, "cursor: calls never pending")
        let ids = p.items().map(\.id)
        check(Set(ids).count == ids.count && ids.allSatisfy { $0.contains("cu@") }, "cursor: ids from byte offsets")
        if case .toolChips(let c) = items[2].kind { check(c.flatMap(\.calls).map(\.summary) == ["ls", "/tmp/demo/a.txt", "/tmp/demo/a.txt"], "cursor: call summaries") }
        let root = NSTemporaryDirectory() + "cu-\(UUID().uuidString)"
        let sid = "11111111-2222-3333-4444-555555555555"
        try? FileManager.default.createDirectory(atPath: "\(root)/proj/agent-transcripts/\(sid)", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(root)/proj/agent-transcripts/\(sid)/\(sid).jsonl", contents: Data())
        check(SessionLog.locate(agent: "cursor", sessionId: sid, dir: root)?.lastPathComponent == "\(sid).jsonl"
              && SessionLog.locate(agent: "cursor", sessionId: "../x", dir: root) == nil, "cursor: locate by id")
        try? FileManager.default.removeItem(atPath: root)
    }
}

// Session fallback (SessionResolver): pure parts only; no ps/lsof here.
@MainActor func checksSessionFallback() async throws {
    do {
        typealias R = SessionResolver
        let sock = "/home/u/.config/herdr/herdr.sock", other = "/home/u/.config/herdr/sessions/t/herdr.sock"
        let ps = """
          100     1 Sat Oct 10 13:50:00 2026     -zsh HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH=\(sock) TERM=x
          101   100 Sat Oct 10 13:55:02 2026     codex HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH=\(sock) TERM=x
          102   101 Sat Oct 10 13:56:00 2026     /bin/zsh -c ls HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH=\(sock)
          103   100 Sat Oct 10 13:51:00 2026     vim HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH=\(sock)
          200     1 Sat Oct 10 13:40:00 2026     -zsh HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH=\(other)
          201   200 Sat Oct 10 13:59:00 2026     codex HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH=\(other)
          300     1 Sat Oct 10 13:40:00 2026     -zsh HERDR_PANE_ID=w1:p10 HERDR_SOCKET_PATH=\(sock)
          301   300 Sat Oct 10 14:00:00 2026     codex HERDR_PANE_ID=w1:p10 HERDR_SOCKET_PATH=\(sock)
          garbage line
        """
        let procs = R.parsePS(ps)
        check(procs.count == 8, "resolver: ps lines parsed")
        check(R.agentProcess(paneId: "w1:p1", socketPath: sock, procs: procs)?.pid == 101, "resolver: newest shell child of the pane, this session only")
        check(R.agentProcess(paneId: "w1:p1", socketPath: other, procs: procs)?.pid == 201, "resolver: other session's pane is separate")
        check(R.agentProcess(paneId: "w1:p10", socketPath: sock, procs: procs)?.pid == 301, "resolver: w1:p1 does not match w1:p10")
        check(R.agentProcess(paneId: "w9:p9", socketPath: sock, procs: procs) == nil, "resolver: unknown pane")
        check(Set(R.subtree(101, procs: procs)) == [101, 102], "resolver: process subtree")
        let h = NSHomeDirectory()
        let ro = h + "/.codex/sessions/2026/10/10/rollout-2026-10-10T13-55-04-abc.jsonl"
        check(R.logPath(openFiles: [h + "/.codex/logs_2.sqlite", ro, ro], kind: "codex") == ro, "resolver: open rollout")
        check(R.logPath(openFiles: [ro, h + "/.codex/sessions/2026/10/10/rollout-2026-10-10T14-00-00-def.jsonl"], kind: "codex") == nil, "resolver: two open rollouts: no guess")
        check(R.logPath(openFiles: [ro], kind: "claude") == nil && R.logPath(openFiles: [h + "/.claude/projects/x/id.jsonl"], kind: "claude") != nil, "resolver: log kind per agent")
        check(R.isClaimed(ro, ["abc"]) && R.isClaimed(ro, [ro]) && !R.isClaimed(ro, ["bc"]) && !R.isClaimed(ro, []), "resolver: claimed by id or path")
        // codex cwd + start match on a temp sessions tree (synthetic meta lines)
        let root = NSTemporaryDirectory() + "hkres-\(UUID().uuidString)"
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        let c = Calendar.current.dateComponents([.year, .month, .day], from: start)
        let day = String(format: "%@/%04d/%02d/%02d", root, c.year!, c.month!, c.day!)
        try? FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
        func roll(_ dt: TimeInterval, _ id: String, cwd: String) -> String {
            let t = start.addingTimeInterval(dt)
            let p = "\(day)/rollout-\(f.string(from: t))-\(id).jsonl"
            let meta = #"{"timestamp":"x","type":"session_meta","payload":{"id":"\#(id)","timestamp":"\#(iso.string(from: t))","cwd":"\#(cwd)"}}"# + "\n"
            FileManager.default.createFile(atPath: p, contents: Data(meta.utf8))
            return p
        }
        _ = roll(-600, "old", cwd: "/w/a")
        let hit = roll(2, "hit", cwd: "/w/a")
        _ = roll(5, "elsewhere", cwd: "/w/b")
        check(R.codexMeta(hit)?.cwd == "/w/a", "resolver: codex session_meta read")
        check(R.codexCandidates(dir: root, cwd: "/w/a", after: start, now: start.addingTimeInterval(60)) == [hit], "resolver: codex cwd + start: one match")
        check(R.codexCandidates(dir: root, cwd: "/w/a/", after: start, now: start.addingTimeInterval(60)) == [hit], "resolver: cwd compared standardized")
        _ = roll(30, "second", cwd: "/w/a")
        check(R.codexCandidates(dir: root, cwd: "/w/a", after: start, now: start.addingTimeInterval(60)).count == 2, "resolver: two matches are both returned (caller refuses)")
        try? FileManager.default.removeItem(atPath: root)
    }
}
