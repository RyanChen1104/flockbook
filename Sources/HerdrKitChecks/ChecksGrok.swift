import Foundation
@testable import HerdrKit

// Grok Build: `<GROK_HOME>/sessions/<encoded cwd>/<id>/updates.jsonl`, a stream of ACP `session/update` lines.
@MainActor func checksGrok() async throws {
    let gl = String(decoding: fixture("grok.jsonl"), as: UTF8.self).split(separator: "\n").map(String.init)
    let items = SessionLog.parse(lines: gl)
    check(describe(items) == ["user:List the files in /tmp/demo.", "asst:Looking.", "chips:Searched the code 2 times|Ran a command|Read a file|Edited a file",
                              "asst:Done with a.txt.", "user:Line one.\nLine two.", "asst:Working.", "chips:Ran a command", "status", "user:Again.",
                              "perm:make test"], "grok: items \(describe(items))")
    check(!items.contains { if case .assistantText(let t) = $0.kind { return t.contains("Hidden") }; return false }, "grok: thinking hidden")
    check(items.first?.timestamp == Date(timeIntervalSince1970: 1_792_000_000.5), "grok: time from agentTimestampMs")
    check({ if case .status("Interrupted") = items[7].kind { true } else { false } }(), "grok: a cancelled turn says Interrupted")
    let calls = chipCalls(items)
    check(calls.map(\.toolName) == ["Grep", "Glob", "Bash", "Read", "Edit", "Bash"], "grok: tools under Claude Code's names \(calls.map(\.toolName))")
    check(calls.map(\.summary) == [".", "/tmp/demo", "ls", "/tmp/demo/a.txt", "/tmp/demo/a.txt", "make"], "grok: call summaries \(calls.map(\.summary))")
    check(calls.map(\.output) == ["found 1 matches", "- /tmp/demo/\n  - a.txt", "a.txt\n", "hello", "no match", nil]
          && calls.map(\.isError) == [false, false, false, false, true, false], "grok: results and a failed call")
    check(!calls[0].input.contains("variant"), "grok: the update's rawInput tag is not shown")

    // Fed line by line (offsets as the tailer gives them) = batch; a chunk that continues a message keeps its id.
    var p = ConversationParser()
    var off: UInt64 = 0
    var firstUser: [String] = []
    for (i, l) in gl.enumerated() {
        p.feed(line: l, offset: off); off += UInt64(l.utf8.count + 1)
        if i == 1 || i == 2 { firstUser.append(p.items().first?.id ?? "") }
    }
    check(p.items().map(\.id) == items.map(\.id) && Set(items.map(\.id)).count == items.count, "grok: incremental feed = batch, ids unique")
    check(firstUser.count == 2 && firstUser[0] == firstUser[1] && describe(p.items()).first == "user:List the files in /tmp/demo.", "grok: merged chunks keep the first id")
    check(p.hasOpenToolUse, "grok: the last call is open")
    // A turn that ends closes its calls: nothing stays pending.
    let ended = SessionLog.parse(lines: gl + [#"{"timestamp":1792000009,"method":"_x.ai/session/update","params":{"sessionId":"s","update":{"sessionUpdate":"turn_completed","stop_reason":"end_turn"},"_meta":{"eventId":"s-99"}}}"#])
    check(!ended.contains { if case .permissionRequest = $0.kind { return true }; return false }, "grok: turn end closes open calls")

    // Where the logs are: GROK_HOME, else ~/.grok; found by id in any cwd group (long cwds use a slug folder).
    check(SessionLog.defaultDir(agent: "grok", env: ["GROK_HOME": "/g"]) == "/g/sessions"
          && SessionLog.defaultDir(agent: "grok", env: [:]) == NSHomeDirectory() + "/.grok/sessions", "grok: GROK_HOME or ~/.grok")
    let root = NSTemporaryDirectory() + "gk-\(UUID().uuidString)"
    let sid = "00000000-0000-7000-8000-000000000001"
    let fm = FileManager.default
    try? fm.createDirectory(atPath: "\(root)/slug-0a1b2c/\(sid)", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: "\(root)/%2Fw%2Fa/other", withIntermediateDirectories: true)
    fm.createFile(atPath: "\(root)/slug-0a1b2c/\(sid)/updates.jsonl", contents: Data((gl.prefix(7).joined(separator: "\n") + "\n").utf8))
    fm.createFile(atPath: "\(root)/slug-0a1b2c/\(sid)/chat_history.jsonl", contents: Data())
    check(SessionLog.locate(agent: "grok", sessionId: sid, dir: root)?.path == "\(root)/slug-0a1b2c/\(sid)/updates.jsonl"
          && SessionLog.locate(agent: "grok", sessionId: "../\(sid)", dir: root) == nil
          && SessionLog.locate(agent: "grok", sessionId: "other", dir: root) == nil, "grok: locate updates.jsonl by id")
    var it = SessionLog(sessionId: sid, agent: "grok").snapshots(projectsDir: root, pollInterval: .milliseconds(30)).makeAsyncIterator()
    var seen: [String] = []
    for _ in 0..<6 { if let s = await it.next(), !s.items.isEmpty { seen = describe(s.items); break } }
    check(seen == ["user:List the files in /tmp/demo.", "asst:Looking.", "perm:."], "grok: tailed from the session folder \(seen)")
    try? fm.removeItem(atPath: root)

    // A pane herdr reports without a session (no integration installed): the open events.jsonl, or active_sessions.json.
    typealias R = SessionResolver
    let h = NSHomeDirectory()
    let open = [h + "/.grok/logs/unified.jsonl", h + "/.grok/sessions/%2Fw%2Fa/\(sid)/events.jsonl", h + "/.grok/memtrace/1-2.jsonl"]
    check(R.logPath(openFiles: open, kind: "grok") == h + "/.grok/sessions/%2Fw%2Fa/\(sid)/updates.jsonl", "grok resolver: open events.jsonl names the folder")
    check(R.logPath(openFiles: open + [h + "/.grok/sessions/%2Fw%2Fb/s2/events.jsonl"], kind: "grok") == nil, "grok resolver: two sessions: no guess")
    check(R.logPath(openFiles: ["/g/sessions/x/s3/events.jsonl"], kind: "grok", grokHome: "/g") == "/g/sessions/x/s3/updates.jsonl"
          && R.logPath(openFiles: ["/g/sessions/x/s3/events.jsonl"], kind: "grok") == nil, "grok resolver: GROK_HOME of the agent")
    check(R.logPath(openFiles: open, kind: "claude") == nil, "grok resolver: not for other agents")
    check(R.grokHome("grok --cwd /w GROK_HOME=/g TERM=x") == "/g" && R.grokHome("grok TERM=x") == h + "/.grok", "grok resolver: GROK_HOME from the agent's env")
    let active = Data(#"[{"session_id":"s-old","pid":7,"cwd":"/w"},{"session_id":"\#(sid)","pid":42,"cwd":"/w"}]"#.utf8)
    check(R.grokSession(active: active, pids: [41, 42]) == sid && R.grokSession(active: active, pids: [40]) == nil
          && R.grokSession(active: Data("x".utf8), pids: [42]) == nil, "grok resolver: active session by pid")
    check(R.isClaimed(h + "/.grok/sessions/%2Fw%2Fa/\(sid)/updates.jsonl", [sid]), "grok resolver: claimed by the folder's id")
}
