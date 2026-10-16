import Foundation
@testable import HerdrKit

// `HerdrKitChecks --queue-live <pane_id> [<claude log.jsonl>]`: the agents' own queue, pulled back from a real Claude Code
// or Codex pane, in the named session c9-input-test only (never the default session). Waits up to 90 s for a working agent
// with a queue on screen, pulls it back with QueuePull and HerdrQueuePullIO (the code the Mac and the hub call), and checks
// the turn: working before the keys, and still working (or ended normally) after them.
@MainActor func modeQueueLive() async throws {
    guard let i = CommandLine.arguments.firstIndex(of: "--queue-live") else { return }
    let a = CommandLine.arguments
    guard a.count > i + 1 else { print("usage: --queue-live <pane_id> [<claude log.jsonl>]"); exit(2) }
    let pane = a[i + 1], logPath = a.count > i + 2 ? a[i + 2] : nil
    let client = HerdrClient(session: .named("c9-input-test"))   // never the default session
    var failures = 0
    func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("queue-live: \(n) \(ok ? "ok" : "FAIL")") }
    func agent() async -> Agent? { (try? await client.snapshot())?.flatMap(\.tabs).flatMap(\.panes).first { $0.id == pane }?.agent }
    func log() -> [String?] {
        guard let logPath, let d = FileManager.default.contents(atPath: logPath) else { return [] }
        var p = ConversationParser()
        for l in String(decoding: d, as: UTF8.self).split(separator: "\n") { p.feed(line: String(l)) }
        return p.queue.items
    }

    /// The live pane, with every key list it sends.
    final class Recorder: QueuePull.IO {
        let inner: HerdrQueuePullIO
        var sent: [[String]] = []
        init(_ inner: HerdrQueuePullIO) { self.inner = inner }
        func agent() async -> Agent? { await inner.agent() }
        func screen() async -> String? { await inner.screen() }
        func keys(_ k: [String]) async -> Bool { sent.append(k); return await inner.keys(k) }
        func settle() async { await inner.settle() }
    }

    let start = Date()
    var found: (Agent, QueuedInput, String)?
    while found == nil, Date().timeIntervalSince(start) < 90 {
        if let ag = await agent(), let s = try? await client.visibleText(paneId: pane),
           let q = QueuedInput.read(agent: ag, screen: s, log: log()), !q.items.isEmpty { found = (ag, q, s) }
        else { try? await Task.sleep(for: .milliseconds(300)) }
    }
    guard let (ag, q, before) = found else { step("a working agent with a queue on screen within 90 s", false); exit(1) }
    print("queue-live: \(ag.kind) queue \(q.items.map { $0 ?? "<no text>" }) pullable \(q.pullable) (log \(log().count) entries)")
    step("the agent works before the keys", ag.status == .working)

    let io = Recorder(HerdrQueuePullIO(client: client, paneId: pane, allowed: { true }))
    let r = await QueuePull.run(expect: ag, log: log(), io: io)
    print("queue-live: outcome \(r)")
    print("queue-live: keys \(io.sent)")
    let flat = io.sent.flatMap { $0 }
    step("only Up, shift+left and ctrl+u went out; never Escape", flat.allSatisfy(QueuePull.allowedKeys.contains) && !flat.contains { $0.lowercased().hasPrefix("esc") })
    let want = (q.pullsAll ? q.items : Array(q.items.suffix(1))).compactMap { $0 }.joined(separator: "\n")
    step("pulled: the queued text came back (\(want.debugDescription))", r == .pulled(want))

    // The turn after the keys: read again now and 3 s later. Working, or a turn that ended normally; no interrupt notice.
    for wait in [0, 3] {
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        let st = await agent()?.status
        let s = (try? await client.visibleText(paneId: pane)) ?? ""
        step("+\(wait) s: status \(st?.rawValue ?? "none") is working or ended normally", st == .working || st == .idle || st == .done)
        step("+\(wait) s: no new interrupt notice", QueuePull.interrupts(s) <= QueuePull.interrupts(before))
    }
    let left = QueuedInput.read(agent: await agent(), screen: try? await client.visibleText(paneId: pane), log: log())
    step("the pulled message left the agent's queue (left: \(left?.items.map { $0 ?? "?" } ?? []))",
         q.pullsAll ? (left?.items.isEmpty ?? true) : (left?.items.count ?? 0) == q.items.count - 1)
    print("queue-live: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
    exit(failures == 0 ? 0 : 1)
}
