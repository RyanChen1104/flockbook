import Foundation
@testable import HerdrKit

func checksLogTimes() async {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let ages: [(TimeInterval, String)] = [(0, "now"), (44, "now"), (45, "1m"), (119, "1m"), (1445, "24m"), (3599, "59m"),
                                          (3600, "1h"), (86399, "23h"), (86400, "1d"), (777605, "9d"), (-30, "now")]
    for (secs, want) in ages {
        let got = LogAge.label(t0 - secs, now: t0)
        check(got == want, "log age: \(Int(secs)) s -> \(want) (\(got))")
    }

    // The log's file time, looked up at most once per 30 s per session; the path is found once and kept.
    var looks: [(String, URL?)] = []
    let url = URL(fileURLWithPath: "/logs/s-a.jsonl")
    var mtime = t0 - 600
    let cache = LogTimeCache { sid, kind, known in
        looks.append((sid, known))
        return sid == "s-a" ? (url, mtime) : (nil, nil)
    }
    cache.refresh([("s-a", "claude"), ("s-none", "codex")], now: t0)
    check(cache.time("s-a") == t0 - 600, "log times: the log's file time")
    check(cache.time("s-none") == nil, "log times: no log, no time")
    check(looks.count == 2 && looks[0].1 == nil, "log times: first pass looks each session up (\(looks.count))")
    mtime = t0 - 5
    cache.refresh([("s-a", "claude"), ("s-none", "codex")], now: t0 + 10)
    check(looks.count == 2, "log times: no look again within 30 s (\(looks.count))")
    check(cache.time("s-a") == t0 - 600, "log times: the time kept until the next look")
    cache.refresh([("s-a", "claude"), ("s-none", "codex")], now: t0 + 31)
    check(looks.count == 4, "log times: looked again after 30 s (\(looks.count))")
    check(looks.first { $0.0 == "s-a" && $0.1 != nil }?.1 == url, "log times: the second look reuses the found path")
    check(cache.time("s-a") == t0 - 5, "log times: the new file time after the second look")
    cache.refresh([("s-none", "codex")], now: t0 + 62)
    check(cache.time("s-a") == nil, "log times: a session no longer shown is dropped")

    // A tab's time: the newest of its agents' logs; a tab with no agent log (a shell) has none.
    let ag = { (n: String, sid: String?) in Agent(name: n, kind: "claude", status: .idle, sessionId: sid, title: n) }
    let tab = Tab(id: "t", label: "t", number: 1, panes: [
        Pane(id: "p1", terminalId: "x1", cwd: "/", agent: ag("a", "s-a")), Pane(id: "p2", terminalId: "x2", cwd: "/", agent: ag("b", "s-b")),
        Pane(id: "p3", terminalId: "x3", cwd: "/", agent: nil)], status: .idle)
    let shell = Tab(id: "s", label: "s", number: 2, panes: [Pane(id: "p4", terminalId: "x4", cwd: "/", agent: nil)], status: .idle)
    let times = ["s-a": t0 - 300, "s-b": t0 - 60]
    check(LogTimeCache.newest(of: tab, times: times) == t0 - 60, "log times: a tab shows its newest agent log")
    check(LogTimeCache.newest(of: shell, times: times) == nil, "log times: a shell tab shows no time")
}
