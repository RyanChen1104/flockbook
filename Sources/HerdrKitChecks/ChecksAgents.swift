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

// A teammate of a Claude Code agent team runs with the lead's HERDR_* env, so herdr can name the teammate's log as the
// pane's session. The pane shows the lead's log instead, or no log; never the teammate's. Synthetic logs only.
@MainActor func checksTeammateSession() async throws {
    typealias R = SessionResolver
    let meta = #"{"type":"agent-setting","sessionId":"s"}"#
    let mate = #"{"type":"user","sessionId":"s","teamName":"team-1","agentName":"helper","message":{"role":"user","content":"hi"}}"#
    let lead = #"{"type":"user","sessionId":"s","message":{"role":"user","content":"hi"}}"#
    func data(_ ls: String...) -> Data { Data((ls.joined(separator: "\n") + "\n").utf8) }
    check(R.teammateVerdict(data(meta, mate)) == true, "teammate: a message line with teamName and agentName marks a teammate log")
    check(R.teammateVerdict(data(meta, lead, mate)) == false, "teammate: the first message line decides (a lead log)")
    check(R.teammateVerdict(data(meta)) == nil && R.teammateVerdict(Data()) == nil, "teammate: no message line yet: not decided")
    check(R.claudeFolder("/w/my.app/sub_dir") == "-w-my-app-sub-dir", "teammate: Claude project folder of a cwd")

    let fm = FileManager.default
    let root = NSTemporaryDirectory() + "hkmate-\(UUID().uuidString)"
    let home = root + "/home", projects = root + "/projects", cwd = home + "/proj"
    let t0 = Date(timeIntervalSince1970: 1_791_000_000)
    func log(_ cwd: String, _ id: String, _ line: String, made: Date, modified: Date) -> String {
        let dir = projects + "/" + R.claudeFolder(cwd)
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = dir + "/" + id + ".jsonl"
        fm.createFile(atPath: p, contents: data(meta, line))
        try? fm.setAttributes([.creationDate: made, .modificationDate: modified], ofItemAtPath: p)
        return p
    }
    // The lead is found by identity: the one unclaimed log near the pane's cwd that is not a teammate's and names
    // the teammate's team (the lead created and runs the team). Time only skips logs not written lately.
    func mateLine(_ team: String) -> String { #"{"type":"user","sessionId":"s","teamName":""# + team + #"","agentName":"helper","message":{"role":"user","content":"hi"}}"# }
    func leadLine(_ team: String) -> String { #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","input":{"team_name":""# + team + #""}}]}}"# }
    check(R.teamName(data(meta, mate)) == "team-1" && R.teamName(data(meta, lead)) == nil, "teammate: the team of a teammate log")
    _ = log(cwd + "/web", "mate1", mate, made: t0, modified: t0.addingTimeInterval(120))
    let leadPath = log(cwd, "lead1", lead + "\n" + leadLine("team-1"), made: t0.addingTimeInterval(-3600), modified: t0.addingTimeInterval(60))
    _ = log(cwd, "other1", lead + "\n" + leadLine("team-9"), made: t0.addingTimeInterval(-3600), modified: t0.addingTimeInterval(80))
    _ = log(cwd, "busy1", lead + "\n" + leadLine("team-1"), made: t0.addingTimeInterval(-60), modified: t0.addingTimeInterval(90))
    _ = log(cwd, "old1", lead, made: t0.addingTimeInterval(-7200), modified: t0.addingTimeInterval(-3000))
    _ = log(home, "home1", lead + "\n" + leadLine("team-1"), made: t0, modified: t0.addingTimeInterval(300))
    var scan = R.LeadScan()
    check(R.leadLog(projectsDir: projects, cwd: cwd, home: home, team: "team-1", since: t0, claimed: ["busy1"], scan: &scan) == leadPath,
          "teammate: the lead is the one unclaimed non-teammate log that names the team")
    check(R.leadLog(projectsDir: projects, cwd: cwd + "/web/src", home: home, team: "team-1", since: t0, claimed: ["busy1"], scan: &scan) == leadPath,
          "teammate: ancestor folders are searched, the teammate's own log skipped")
    check(R.leadLog(projectsDir: projects, cwd: cwd, home: home, team: "team-1", since: t0, claimed: [], scan: &scan) == nil,
          "teammate: two logs name the team: no lead")
    check(R.leadLog(projectsDir: projects, cwd: cwd, home: home, team: "team-2", since: t0, claimed: [], scan: &scan) == nil,
          "teammate: no log names the team: no lead, never the newest log")
    check(R.leadLog(projectsDir: projects, cwd: home + "/elsewhere", home: home, team: "team-1", since: t0, claimed: [], scan: &scan) == nil,
          "teammate: the home folder is not searched")

    // A lead whose first message line is over the 1 MiB head limit is still found.
    let hugePath = log(home + "/huge", "huge1", #"{"type":"user","message":{"role":"user","content":""# + String(repeating: "x", count: 1_200_000) + #""}}"# + "\n" + leadLine("team-h"),
                       made: t0, modified: t0.addingTimeInterval(60))
    check(R.leadLog(projectsDir: projects, cwd: home + "/huge", home: home, team: "team-h", since: t0, claimed: [], scan: &scan) == hugePath,
          "teammate: a lead with a first message line over the head limit is found")

    // The scan reads only what a log added since the last pass, and finds a name cut by a chunk edge.
    func append(_ p: String, _ text: String) { if let fh = FileHandle(forWritingAtPath: p) { fh.seekToEndOfFile(); fh.write(Data(text.utf8)); fh.closeFile() } }
    func size(_ p: String) -> UInt64 { (try? fm.attributesOfItem(atPath: p))?[.size] as? UInt64 ?? 0 }
    var small = R.LeadScan(chunk: 7)
    let grow = log(home + "/grow", "grow1", lead, made: t0, modified: t0)
    check(small.mentions(grow, "team-g") == false && small.bytesRead == size(grow), "teammate: a log without the team name does not name it")
    _ = small.mentions(grow, "team-g")
    check(small.bytesRead == size(grow), "teammate: an unchanged log is not read again")
    let before = size(grow)
    append(grow, leadLine("team-g") + "\n")
    check(small.mentions(grow, "team-g") == true && small.bytesRead > before && small.bytesRead <= size(grow),
          "teammate: only the bytes added since are read, and a name in them is found")
    fm.createFile(atPath: grow, contents: Data((lead + "\n").utf8))
    check(small.mentions(grow, "team-g") == false, "teammate: a log cut shorter is read again from the start")
    let fresh = grow + ".new"
    fm.createFile(atPath: fresh, contents: Data(("team-g " + String(repeating: "y", count: Int(before)) + "\n").utf8))
    _ = try? fm.replaceItemAt(URL(fileURLWithPath: grow), withItemAt: URL(fileURLWithPath: fresh))
    check(small.mentions(grow, "team-g") == true, "teammate: a log replaced by another file is read again from the start")

    // Each pass reads at most a byte budget; a log not read to its end gives no lead this pass, and the next goes on.
    var budget = R.LeadScan(chunk: 64, budget: 256)
    let slow = home + "/slow"
    let slowLead = log(slow, "lead6", lead + "\n" + leadLine("team-s"), made: t0, modified: t0.addingTimeInterval(60))
    _ = log(slow, "big6", lead + "\n" + String(repeating: "z", count: 1000), made: t0, modified: t0.addingTimeInterval(60))
    check(R.leadLog(projectsDir: projects, cwd: slow, home: home, team: "team-s", since: t0, claimed: [], scan: &budget) == nil && budget.bytesRead <= 256 + 64,
          "teammate: a pass stops at its byte budget and gives no lead before every log is read")
    var passes = 1, got: String?
    while got == nil, passes < 10 { budget.endPass(); got = R.leadLog(projectsDir: projects, cwd: slow, home: home, team: "team-s", since: t0, claimed: [], scan: &budget); passes += 1 }
    check(got == slowLead && passes > 1, "teammate: later passes go on where the last stopped and find the lead")

    // A log whose first message line is not yet whole, with teamName already written, is not a lead candidate.
    let part = home + "/part"
    let partLead = log(part, "lead7", lead + "\n" + leadLine("team-p"), made: t0, modified: t0.addingTimeInterval(60))
    let partMate = log(part, "mate7", lead, made: t0, modified: t0.addingTimeInterval(60))
    fm.createFile(atPath: partMate, contents: Data((meta + "\n" + #"{"parentUuid":null,"isSidechain":false,"teamName":"team-p""#).utf8))
    check(R.leadLog(projectsDir: projects, cwd: part, home: home, team: "team-p", since: .distantPast, claimed: [], scan: &scan) == partLead,
          "teammate: an undecided log is never a lead candidate")

    // The resolver: two teammate panes on one cwd, teammates begun at different times, each gets its own lead.
    let r = R(socketPath: "/nonexistent.sock", projectsDir: projects, home: home)
    let duo = home + "/duo"
    _ = log(duo, "mateA", mateLine("team-a"), made: t0.addingTimeInterval(10), modified: t0.addingTimeInterval(40))
    _ = log(duo, "mateB", mateLine("team-b"), made: t0.addingTimeInterval(20), modified: t0.addingTimeInterval(40))
    let leadA = log(duo, "leadA", lead + "\n" + leadLine("team-a"), made: t0, modified: t0.addingTimeInterval(12))
    let leadB = log(duo, "leadB", lead + "\n" + leadLine("team-b"), made: t0, modified: t0.addingTimeInterval(15))
    let both = await r.leads([R.LeadAsk(paneId: "w2:p1", sessionId: "mateA", cwd: duo), R.LeadAsk(paneId: "w2:p2", sessionId: "mateB", cwd: duo)], claimed: [])
    check(both == ["w2:p1": LeadSwap(teammate: "mateA", lead: leadA), "w2:p2": LeadSwap(teammate: "mateB", lead: leadB)],
          "teammate: two panes on one cwd each get the lead that names their team")
    check(await r.leads([R.LeadAsk(paneId: "w2:p1", sessionId: "mateA", cwd: duo)], claimed: ["leadA"]) == ["w2:p1": LeadSwap(teammate: "mateA", lead: nil)],
          "teammate: a lead another pane claims is not this pane's")
    check(await r.leads([R.LeadAsk(paneId: "w2:p1", sessionId: "leadB", cwd: duo)], claimed: []).isEmpty,
          "teammate: a lead log herdr names is kept")
    check(await r.leads([R.LeadAsk(paneId: "w2:p1", sessionId: "mateA", cwd: duo)], claimed: []) == ["w2:p1": LeadSwap(teammate: "mateA", lead: "leadB")],
          "teammate: the lead id herdr gave last time comes before the search")
    check(await r.leads([R.LeadAsk(paneId: "w2:p1", sessionId: "mateA", cwd: duo), R.LeadAsk(paneId: "w2:p2", sessionId: "mateB", cwd: duo)], claimed: [])
          == ["w2:p1": LeadSwap(teammate: "mateA", lead: "leadB"), "w2:p2": LeadSwap(teammate: "mateB", lead: nil)],
          "teammate: the lead herdr gave another pane is never found for this pane")
    check(await r.leads([R.LeadAsk(paneId: "w3:p1", sessionId: "mate1", cwd: home + "/elsewhere")], claimed: []) == ["w3:p1": LeadSwap(teammate: "mate1", lead: nil)],
          "teammate: no lead found: no log rather than the teammate's")
    check(await r.leads([R.LeadAsk(paneId: "w3:p2", sessionId: "unknown1", cwd: cwd)], claimed: []).isEmpty,
          "teammate: a log not found yet is kept")
    try? fm.removeItem(atPath: root)

    // A first message line cut off by the read limit still shows its team keys, which come before the message.
    func cut(_ s: String) -> Data { Data((meta + "\n" + s).utf8) }
    let big = String(repeating: "x", count: 4096)
    check(R.teammateVerdict(cut(#"{"parentUuid":null,"isSidechain":false,"teamName":"team-1","agentName":"helper","type":"user","message":{"role":"user","content":""# + big)) == true,
          "teammate: a cut first message line with teamName and agentName marks a teammate log")
    check(R.teammateVerdict(cut(#"{"parentUuid":null,"type":"user","message":{"role":"user","content":"say \"teamName\":\"t\",\"agentName\":\"a\" "# + big)) == false,
          "teammate: a cut first message line with type and no teamName before the message is a lead's (quoted keys in the text do not count)")

    // The store puts the swap in the pane while herdr still names that teammate log.
    func ws(_ sid: String?) -> [Workspace] {
        [Workspace(id: "w1", label: "w", tabs: [Tab(id: "t1", label: "t", number: 1, panes: [
            Pane(id: "w1:p1", terminalId: "x", cwd: cwd, agent: Agent(name: "claude", kind: "claude", status: .working, sessionId: sid, title: "c"))
        ], status: .working)])]
    }
    func agent(_ w: [Workspace]) -> Agent? { w[0].tabs[0].panes[0].agent }
    let lifted = HerdrStore.withFallbacks(ws("mate1"), resolved: [:], swaps: ["w1:p1": LeadSwap(teammate: "mate1", lead: leadPath)])
    check(agent(lifted)?.sessionId == leadPath && agent(lifted)?.sessionResolved == true, "teammate: the store shows the lead's log, marked as not herdr's")
    check(agent(HerdrStore.withFallbacks(ws("mate1"), resolved: [:], swaps: ["w1:p1": LeadSwap(teammate: "mate1", lead: nil)]))?.sessionId == nil,
          "teammate: the store shows no log when there is no lead")
    check(agent(HerdrStore.withFallbacks(ws("lead2"), resolved: [:], swaps: ["w1:p1": LeadSwap(teammate: "mate1", lead: leadPath)]))?.sessionId == "lead2",
          "teammate: once herdr names another log, the old swap does nothing")
    check(HerdrStore.claims(ws("mate1"), resolved: ["w9:p1": "/x/found.jsonl"]) == ["mate1", "/x/found.jsonl"],
          "teammate: logs the resolver found for other panes are claimed too")
}
