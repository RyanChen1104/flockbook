import Foundation
@testable import HerdrKit

// The hub and the agents' own queues: a `queued` push for a watched pane, and `pullQueued`, which takes the queue back
// into the device's composer through the backend (QueuePull) only after the hub's own checks.
@MainActor func checksHubQueue() async throws {
    let rule = String(repeating: "─", count: 60)
    func screen(_ queued: [String], input: String = "❯ Press up to edit queued messages") -> String {
        (["⏺ Working on it"] + queued.map { "❯ " + $0 } + ["  ctrl+enter to send now", "· Baking… (12s)", rule, input, rule]).joined(separator: "\n")
    }
    func ws(_ status: AgentStatus, kind: String = "claude") -> [Workspace] {
        let a = Agent(name: kind, kind: kind, status: status, sessionId: "s1", title: "Fix the build")
        return [Workspace(id: "w1", label: "web", tabs: [Tab(id: "w1:t1", label: "build", number: 1,
                          panes: [Pane(id: "w1:p1", terminalId: "term_1", cwd: "/work", agent: a)], status: status)])]
    }
    func msg(_ json: String) -> Data { Data(json.utf8) }
    func types(_ ms: [HubMessage]) -> [String] { ms.map(\.type) }
    func reply(_ ms: [HubMessage]) -> HubReply? { ms.last.flatMap { if case .reply(let r) = $0 { r } else { nil } } }
    func queued(_ ms: [HubMessage]) -> HubQueued? { ms.lazy.compactMap { if case .queued(let q) = $0 { q } else { nil } }.first }
    func pulled(_ ms: [HubMessage]) -> HubPulled? { ms.lazy.compactMap { if case .pulled(let p) = $0 { p } else { nil } }.first }
    let devices = MemoryDeviceStore()
    devices.add(token: "tok-read", device: HubDevice(id: "d-read", name: "Phone", level: .read))
    devices.add(token: "tok-input", device: HubDevice(id: "d-input", name: "Tablet", level: .input))
    func session(_ b: FakeHubBackend, token: String = "tok-input") async -> HubSession {
        let s = HubSession(backend: b, devices: devices)
        _ = await s.receive(msg(#"{"v":1,"type":"hello","id":"h","token":"\#(token)","client":"test","clientVersion":"1"}"#))
        return s
    }
    let pull = msg(#"{"v":1,"type":"pullQueued","id":"q1","pane":"w1:p1"}"#)

    // The push.
    do {
        let b = FakeHubBackend(workspaces: ws(.working))
        b.screens["w1:p1"] = screen(["QC reply GAMMA", "QD reply DELTA"])
        b.queuedLogs["s1"] = ["QC reply GAMMA", nil]
        let s = await session(b)
        let w = await s.receive(msg(#"{"v":1,"type":"watch","id":"c1","pane":"w1:p1"}"#))
        let q = queued(w)
        check(q?.items == ["QC reply GAMMA", "QD reply DELTA"] && q?.pullable == true && q?.pullsAll == true && q?.agent == "claude",
              "hub queue: watch pushes the queue; the log's missing text comes from the screen (\(String(describing: q)))")
        check(await s.tick().isEmpty, "hub queue: no change, no push")
        b.screens["w1:p1"] = screen(["QC reply GAMMA", "QD reply DELTA"], input: "❯ typing")
        check(queued(await s.tick())?.pullable == false, "hub queue: text typed in the agent: not pullable, pushed")
        b.screens["w1:p1"] = "⏺ Done\n" + rule + "\n❯ \n" + rule
        let gone = queued(await s.tick())
        check(gone?.items == [], "hub queue: the queue went in: an empty push clears it (\(String(describing: gone)))")
        check(await s.tick().isEmpty, "hub queue: still empty, no push")
        let calm = FakeHubBackend(workspaces: ws(.idle))
        calm.screens["w1:p1"] = "⏺ Done"
        let c = await session(calm)
        check(queued(await c.receive(msg(#"{"v":1,"type":"watch","id":"c1","pane":"w1:p1"}"#))) == nil, "hub queue: no queue, no push on watch")
    }

    // Pulling back.
    do {
        let b = FakeHubBackend(workspaces: ws(.working))
        b.screens["w1:p1"] = screen(["QC reply GAMMA"])
        let r = await session(b, token: "tok-read")
        check(reply(await r.receive(pull))?.error?.code == .readOnly && b.pulls.isEmpty, "hub queue: a read-only device cannot pull; nothing sent")
        let s = await session(b)
        b.pullOutcome = .pulled("QC reply GAMMA")
        let out = await s.receive(pull)
        check(pulled(out).map { ($0.pane, $0.text, $0.interrupted, $0.note) } ?? ("", "", true, nil) == ("w1:p1", "QC reply GAMMA", false, nil) && reply(out)?.ok == true && types(out).last == "reply",
              "hub queue: pullQueued -> pulled (the text for the composer), reply ok (\(types(out)))")
        check(b.pulls == ["w1:p1 s1"], "hub queue: the backend pulls with the agent the hub checked")
        b.pullOutcome = .interrupted("QC reply GAMMA")
        let i = await s.receive(pull)
        check(pulled(i)?.interrupted == true && pulled(i)?.text == "QC reply GAMMA" && reply(i)?.ok == true, "hub queue: the turn stopped: pulled with interrupted, the text still comes back")
        b.pullOutcome = .refused("The agent's input box is not empty. Nothing was sent.")
        let f = await s.receive(pull)
        check(pulled(f) == nil && reply(f)?.ok == false && reply(f)?.error?.message.contains("Nothing was sent") == true, "hub queue: refused -> error with the reason")
        b.pullOutcome = .failed("The text is still in the agent's input box. Check the agent's terminal.")
        check(reply(await s.receive(pull))?.error?.code == .failed, "hub queue: failed -> error")

        let pulls = b.pulls.count
        b.screens["w1:p1"] = screen(["QC reply GAMMA"], input: "❯ typing")
        check(reply(await s.receive(pull))?.ok == false && b.pulls.count == pulls, "hub queue: input box not empty: refused by the hub, the backend not called")
        b.screens["w1:p1"] = "⏺ Done"
        check(reply(await s.receive(pull))?.ok == false && b.pulls.count == pulls, "hub queue: no queue: refused, backend not called")
        b.screens["w1:p1"] = screen(["QC reply GAMMA"])
        b.writesEnabled = false
        check(reply(await s.receive(pull))?.error?.code == .readOnly && b.pulls.count == pulls, "hub queue: Allow input off: refused")
        b.writesEnabled = true
        let other = await session(FakeHubBackend(workspaces: ws(.working, kind: "pi")))
        check(reply(await other.receive(pull))?.ok == false, "hub queue: an agent without a queue Flockbook reads: refused")
    }

    // P1-3: the hub keeps the text until the device's composer has it (pulledAck), and sends it again after each
    // hello: a phone that lost the connection before `pulled` arrived still gets it.
    do {
        let b = FakeHubBackend(workspaces: ws(.working))
        b.screens["w1:p1"] = screen(["QC reply GAMMA"])
        b.pullOutcome = .pulled("QC reply GAMMA")
        let s = await session(b)
        let p = pulled(await s.receive(pull))
        check(b.kept == true && p?.id != nil && p?.id == b.pulledTexts.all.first?.id && b.pulledTexts.pending(device: "d-input").map(\.text) == ["QC reply GAMMA"],
              "hub queue: the text is kept for the device that pulled it, and `pulled` carries its id (\(String(describing: p)))")
        func hello(_ token: String) async -> (HubSession, [HubMessage]) {
            let c = HubSession(backend: b, devices: devices)
            return (c, await c.receive(msg(#"{"v":1,"type":"hello","id":"h","token":"\#(token)","client":"test","clientVersion":"1"}"#)))
        }
        let (again, h) = await hello("tok-input")
        check(pulled(h)?.id == p?.id && pulled(h)?.text == "QC reply GAMMA" && types(h).last == "reply",
              "hub queue: after hello the device gets the text its composer did not confirm (\(types(h)))")
        let (other, oh) = await hello("tok-read")
        check(pulled(oh) == nil, "hub queue: another device does not get it")
        let ack = msg(#"{"v":1,"type":"pulledAck","id":"a1","pulled":"\#(p?.id ?? "")"}"#)
        _ = await other.receive(ack)
        check(b.pulledTexts.all.count == 1, "hub queue: another device's pulledAck does not remove it")
        check(reply(await again.receive(ack))?.ok == true && b.pulledTexts.all.isEmpty, "hub queue: pulledAck: the hub forgets it")
        check(pulled(await hello("tok-input").1) == nil, "hub queue: confirmed: not sent again")
        check(reply(await again.receive(ack))?.ok == true, "hub queue: pulledAck again (an id already gone): ok")

        b.pullOutcome = .partial("QC reply GAMMA", "The agent's input box changed while Flockbook cleared it.")
        let part = pulled(await s.receive(pull))
        check(part?.text == "QC reply GAMMA" && part?.note == "The agent's input box changed while Flockbook cleared it." && part?.id != nil,
              "hub queue: a pull that stopped early: the text, kept, with the reason as a note (\(String(describing: part)))")
        // r2 P2-8: sent again after a hello, it carries the reason it was sent with (the terminal may still hold text).
        let (_, h2) = await hello("tok-input")
        check(pulled(h2)?.id == part?.id && pulled(h2)?.note == "The agent's input box changed while Flockbook cleared it.",
              "hub queue: r2 P2-8: a partial pull sent again after hello keeps its reason (\(String(describing: pulled(h2))))")
        b.pullOutcome = .interrupted("QI reply INDIA")
        let stopped = pulled(await s.receive(pull))
        let (_, h3) = await hello("tok-input")
        let again3 = h3.compactMap { if case .pulled(let p) = $0, p.id == stopped?.id { p } else { nil } }.first
        check(again3?.interrupted == true, "hub queue: r2 P2-8: an interrupted pull sent again is still marked interrupted (\(String(describing: again3)))")
        check(b.keptNote != nil, "hub queue: r2 P2-8: while the pull runs the kept text carries a warning (a quit mid-pull is never sent as clean) (\(String(describing: b.keptNote)))")
        b.pullOutcome = .pulled("QJ reply JULIET")
        let clean = pulled(await s.receive(pull))
        let (_, h4) = await hello("tok-input")
        let again4 = h4.compactMap { if case .pulled(let p) = $0, p.id == clean?.id { p } else { nil } }.first
        check(again4 != nil && again4?.note == nil && again4?.interrupted == false, "hub queue: r2 P2-8: a clean pull sent again has no warning (\(String(describing: again4)))")
        b.pulledTexts = FailingPulledStore()
        b.pullOutcome = .partial("QC reply GAMMA", "Could not keep the text.")
        let unkept = pulled(await s.receive(pull))
        check(b.kept == false && unkept?.id == nil && unkept?.text == "QC reply GAMMA", "hub queue: not kept: still sent, without an id (\(String(describing: unkept)))")
    }

    // The kept texts live in a file (mode 600): a quit or a crash between the pull and the composer loses nothing.
    do {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pulled-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "pulled.json")
        let f = FilePulledStore(url: url)
        check(f.keep(PulledText(id: "x1", pane: "w1:p1", device: PulledText.mac, text: "if ready:\n    run()")), "pulled store: keeps")
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
        check(FilePulledStore(url: url).pending(device: PulledText.mac).map(\.text) == ["if ready:\n    run()"] && mode == 0o600,
              "pulled store: a new start reads it back, exactly; the file is mode 600 (\(String(mode, radix: 8)))")
        check(f.take(id: "x1", device: "d-other") == nil && f.take(id: "x1", device: PulledText.mac)?.text == "if ready:\n    run()", "pulled store: only its device takes it")
        check(FilePulledStore(url: url).all.isEmpty, "pulled store: taken: gone from the file")
    }

    // r3 P2-4: the device is removed while its pull runs (Up went out): the text is not kept for it (no composer of
    // it will confirm it), and the box is not cleared (keep says no), so the text stays in the terminal.
    do {
        let own = MemoryDeviceStore()
        own.add(token: "tok-gone", device: HubDevice(id: "d-gone", name: "Old phone", level: .input))
        let b = FakeHubBackend(workspaces: ws(.working))
        b.screens["w1:p1"] = screen(["QC reply GAMMA"])
        b.pullOutcome = .pulled("QC reply GAMMA")
        let s = HubSession(backend: b, devices: own)
        _ = await s.receive(msg(#"{"v":1,"type":"hello","id":"h","token":"tok-gone","client":"test","clientVersion":"1"}"#))
        b.pullDelay = .milliseconds(50)
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(10)); own.revoke(device: "d-gone"); b.pulledTexts.drop(device: "d-gone") }
        _ = await s.receive(pull)
        check(b.kept == false && b.pulledTexts.all.isEmpty, "hub queue: r3 P2-4: removed mid-pull: nothing kept for it, keep says no (\(String(describing: b.kept)), \(b.pulledTexts.all.count))")
        b.pullDelay = .zero
    }

    // r3 P3-5: the panes there are now, from a snapshot herdr gave (an empty one too); nil before any.
    do {
        let none = HerdrStore(session: .named("c9-none"))
        check(none.knownPanes == nil, "store: r3 P3-5: no snapshot yet: panes not known")
        none.setPreview(workspaces: [], connected: true)
        check(none.knownPanes == [], "store: r3 P3-5: an empty snapshot: no panes (the last tab closed) (\(String(describing: none.knownPanes)))")
        none.setPreview(workspaces: ws(.idle), connected: true)
        check(none.knownPanes == ["w1:p1"], "store: the snapshot's panes")
        // r4 P3-3: every snapshot herdr gives counts, the same as the last one too (an empty one at start equals the
        // empty start, so `workspaces` alone never changes): the app prunes on each.
        let fresh = HerdrStore(session: .named("c9-none"))
        fresh.took([])
        fresh.took([])
        check(fresh.snapshots == 2 && fresh.knownPanes == [], "store: r4 P3-3: each snapshot taken counts, an empty one at start too (\(fresh.snapshots))")
    }

    // r2 P2-7: the store has limits (count and bytes): full, it refuses, and the pull then clears nothing. It drops a
    // removed device's texts and those of panes that are gone.
    do {
        let m = MemoryPulledStore(maxCount: 2, maxBytes: 64)
        check(m.keep(PulledText(id: "a", pane: "p1", device: "d1", text: "one")) && m.keep(PulledText(id: "b", pane: "p2", device: "d2", text: "two")),
              "pulled store: keeps up to its count")
        check(!m.keep(PulledText(id: "c", pane: "p1", device: "d1", text: "three")) && m.all.map(\.id) == ["a", "b"], "pulled store: r2 P2-7: full by count: refused, the others stay")
        let n = MemoryPulledStore(maxCount: 10, maxBytes: 64)
        check(!n.keep(PulledText(id: "big", pane: "p1", device: "d1", text: String(repeating: "x", count: 65))) && n.all.isEmpty, "pulled store: r2 P2-7: over the bytes: refused")
        m.drop(device: "d2")
        check(m.all.map(\.id) == ["a"], "pulled store: r2 P2-7: a removed device's texts go (\(m.all.map(\.id)))")
        _ = m.keep(PulledText(id: "d", pane: "p9", device: PulledText.mac, text: "gone pane"))
        m.prune(panes: ["p1"])
        check(m.all.map(\.id) == ["a"], "pulled store: r2 P2-7: texts of panes that are gone go (\(m.all.map(\.id)))")
        m.finish(id: "a", note: "why", interrupted: true)
        check(m.all.first?.note == "why" && m.all.first?.interrupted == true, "pulled store: finish records the pull's end")
        // A file from before `note` and `interrupted` reads back.
        let dir = FileManager.default.temporaryDirectory.appending(path: "pulled-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "pulled.json")
        try Data(#"[{"at":"2026-10-16T10:00:00Z","device":"mac","id":"o1","pane":"w1:p1","text":"old"}]"#.utf8).write(to: url)
        check(FilePulledStore(url: url).all.map(\.text) == ["old"], "pulled store: a file without note and interrupted reads back")
    }

    // Wire format.
    let q = HubQueued(pane: "w1:p1", agent: "codex", items: ["a", nil], pullable: true, pullsAll: false)
    let back = try Hub.decodeHub(try Hub.encode(HubMessage.queued(q)))
    check(back == .queued(q), "hub queue: queued round-trips")
    let p = HubPulled(pane: "w1:p1", text: "a\nb", interrupted: true)
    check(try Hub.decodeHub(try Hub.encode(HubMessage.pulled(p))) == .pulled(p), "hub queue: pulled round-trips")
    check(try Hub.decodeClient(pull).body == .pullQueued(pane: "w1:p1"), "hub queue: pullQueued decodes")
    let ackBack = try Hub.decodeClient(try JSONEncoder().encode(ClientMessage(id: "a", body: .pulledAck(pulled: "x1"))))
    check(ackBack.body == .pulledAck(pulled: "x1"), "hub queue: pulledAck round-trips")
    let withId = HubPulled(id: "x1", pane: "w1:p1", text: "a", interrupted: false, note: "n")
    check(try Hub.decodeHub(try Hub.encode(HubMessage.pulled(withId))) == .pulled(withId), "hub queue: pulled with id and note round-trips")
}

/// A pulled-text store whose saves fail (a full disk).
@MainActor final class FailingPulledStore: MemoryPulledStore {
    override func save() -> Bool { false }
}
