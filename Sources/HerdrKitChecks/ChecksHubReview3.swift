import Foundation
@testable import HerdrKit

// Third security review of the hub (images): the level is checked again right before keys, the agent is bound,
// text keeps the normal input call, paths are pasted only for our own files, the cache folder and its size are
// guarded, queues and decoding are bounded.
@MainActor func checksHubReview3() async throws {
    func msg(_ s: String) -> Data { Data(s.utf8) }
    func code(_ ms: [HubMessage]) -> HubError.Code? { if case .reply(let r)? = ms.last { r.error?.code } else { nil } }
    func ok(_ ms: [HubMessage]) -> Bool { if case .reply(let r)? = ms.last { r.ok } else { false } }
    let png = testImage(.png)!
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hub-r3-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func world(_ status: AgentStatus) -> [Workspace] {
        let a = Agent(name: "claude", kind: "claude", status: status, sessionId: "s1", title: "Fix")
        return [Workspace(id: "w1", label: "web", tabs: [Tab(id: "w1:t1", label: "build", number: 1,
                          panes: [Pane(id: "w1:p1", terminalId: "term_1", cwd: "/work", agent: a)], status: status)])]
    }
    let approvalBox = """
     Bash command
     npm run build
     Do you want to proceed?
     ❯ 1. Yes
       2. No

     Esc to cancel · Tab to amend
    """

    // (1) The device's level now, right before the keys; a downgrade closes the connection.
    do {
        let b = FakeHubBackend(workspaces: world(.idle))
        b.screens["w1:p1"] = "> \n"
        b.imageDirectory = root.appendingPathComponent("levels", isDirectory: true)
        let devices = MemoryDeviceStore()
        devices.add(token: "in", device: HubDevice(id: "d-in", name: "Phone", level: .input))
        let s = HubSession(backend: b, devices: devices, uploads: HubUploadLimiter())
        _ = await s.receive(msg(#"{"v":1,"type":"hello","id":"h","token":"in","client":"t","clientVersion":"1"}"#))
        let down: @MainActor @Sendable () -> Void = { devices.setLevel(.read, device: "d-in") }
        let up: @MainActor @Sendable () -> Void = { devices.setLevel(.input, device: "d-in") }

        b.onScreen = down
        let r1 = await s.receive(msg(#"{"v":1,"type":"send","id":"s1","pane":"w1:p1","text":"hi"}"#))
        check(code(r1) == .readOnly && b.sent.isEmpty, "r3 level: downgraded during the checks -> send readOnly, nothing sent (\(String(describing: code(r1))))")
        b.onScreen = nil; up()

        b.beforeKeys = down
        let r2 = await s.receive(msg(#"{"v":1,"type":"send","id":"s2","pane":"w1:p1","text":"hi"}"#))
        check(!ok(r2) && b.sent.isEmpty && b.allowedAtKeys.last == false, "r3 level: downgraded in the backend -> allowed() false at the keys, nothing sent")
        b.beforeKeys = nil; up()

        let ok3 = await s.receive(msg(#"{"v":1,"type":"send","id":"s3","pane":"w1:p1","text":"hi"}"#))
        check(ok(ok3) && b.allowedAtKeys.last == true && b.sentAgents.last == "s1", "r3 level: input level -> sent, bound to agent session s1")

        // Approve: same rule.
        b.workspaces = world(.blocked)
        b.items["s1"] = [ConversationItem(id: "a1", kind: .permissionRequest(PermissionRequest(title: "Bash command", command: "npm run build", toolName: "Bash", toolUseId: "tu1")))]
        b.screens["w1:p1"] = approvalBox
        b.beforeKeys = down
        let ap = await s.receive(msg(#"{"v":1,"type":"approve","id":"a","pane":"w1:p1","prompt":"tu1","allow":true}"#))
        check(!ok(ap) && b.approved.isEmpty && b.allowedAtKeys.last == false, "r3 level: downgraded before approve keys -> nothing sent (\(String(describing: code(ap))))")
        b.beforeKeys = nil; up()
        b.onScreen = { devices.revoke(device: "d-in") }
        let ap2 = await s.receive(msg(#"{"v":1,"type":"approve","id":"a2","pane":"w1:p1","prompt":"tu1","allow":true}"#))
        check(!ok(ap2) && b.approved.isEmpty, "r3 level: revoked during the checks -> approve refused (\(String(describing: code(ap2))))")
        b.onScreen = nil
        devices.add(token: "in", device: HubDevice(id: "d-in", name: "Phone", level: .input))
        b.workspaces = world(.idle); b.items["s1"] = []; b.screens["w1:p1"] = "> \n"

        // A finished upload after a downgrade is deleted, not held.
        let s2 = HubSession(backend: b, devices: devices, uploads: HubUploadLimiter())
        _ = await s2.receive(msg(#"{"v":1,"type":"hello","id":"h","token":"in","client":"t","clientVersion":"1"}"#))
        s2.afterDecode = down
        let at = await s2.receive(msg(#"{"v":1,"type":"attach","id":"i","upload":"x1","part":0,"parts":1,"data":"\#(png.base64EncodedString())"}"#))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: b.imageDirectory!.path)) ?? []
        check(code(at) == .readOnly && files.isEmpty, "r3 level: downgraded while decoding -> readOnly, the file deleted (\(files.count) files)")
        check(s2.levelChanged, "r3 level: the session sees the downgrade")
        _ = await s2.tick()
        check(s2.closed, "r3 level: a downgraded session closes on its next tick")
        up()
        check(!s.levelChanged, "r3 level: same level as at hello -> no change")
        s.end(); s2.end()
    }

    // (3) The agent the checks saw must still be the pane's agent right before the keys.
    do {
        let fake = FakeHerdr(path: NSTemporaryDirectory() + "hkr3-\(getpid()).sock")
        try fake.start()
        defer { fake.kill() }
        let client = HerdrClient(session: HerdrSession(name: "fake", socketPath: fake.path))
        fake.screen = "> "
        let seen = Agent(name: "claude", kind: "claude", status: .idle, sessionId: "s1", title: "")
        fake.agents = #"[{"pane_id":"w1:p1","agent":"claude","name":"claude","agent_status":"idle","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"s1"}}]"#
        check(await client.readyForText(paneId: "w1:p1", agent: seen), "r3 agent: same agent session -> ready")
        fake.agents = #"[{"pane_id":"w1:p1","agent":"claude","name":"claude","agent_status":"idle","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"s2"}}]"#
        check(await !client.readyForText(paneId: "w1:p1", agent: seen), "r3 agent: another session in the pane now -> not ready")
        fake.agents = #"[{"pane_id":"w1:p1","agent":"codex","name":"codex","agent_status":"idle","agent_session":{"agent":"codex","kind":"id","source":"herdr:codex","value":"s1"}}]"#
        check(await !client.readyForText(paneId: "w1:p1", agent: seen), "r3 agent: another agent kind now -> not ready")
    }

    // (2) (3) (7) What goes as text, what as a paste, and when a new image marker counts.
    do {
        let dir = root.appendingPathComponent("paste", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let uuid = UUID().uuidString
        let mine = dir.appendingPathComponent("remote-\(uuid).jpg").path, composer = dir.appendingPathComponent("\(UUID().uuidString).png").path
        FileManager.default.createFile(atPath: mine, contents: Data([1]))
        FileManager.default.createFile(atPath: composer, contents: Data([1]))
        let plan = ImagePaste.plan("line one\nline two\t \(mine)", directory: dir.path)
        check(plan == [.input("line one\nline two\t "), .paste(mine)], "r3 paste: text with LF and tab goes as normal input, the path as a paste (\(plan))")
        check(ImagePaste.plan("just text\nmore", directory: dir.path) == [.input("just text\nmore")], "r3 paste: text alone is one normal input")
        check(ImagePaste.plan("\(composer) \(mine)", directory: dir.path) == [.paste(composer), .input(" "), .paste(mine)], "r3 paste: two own files pasted")
        check(ImagePaste.plan("x \(dir.path)/remote-0.jpg", directory: dir.path) == [.input("x \(dir.path)/remote-0.jpg")],
              "r3 paste: a name not made by the app stays text")
        let missing = "\(dir.path)/remote-\(UUID().uuidString).jpg"
        check(ImagePaste.plan("x \(missing)", directory: dir.path) == [.input("x \(missing)")], "r3 paste: a path with no file stays text")
        let link = dir.appendingPathComponent("remote-\(UUID().uuidString).png").path
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: mine)
        check(ImagePaste.plan(link, directory: dir.path) == [.input(link)], "r3 paste: a symlink with our name stays text")
        check(ImagePaste.plan("a.png \(dir.path)/a.png", directory: dir.path).allSatisfy { if case .input = $0 { true } else { false } },
              "r3 paste: any other .png is text")
        check(ImagePaste.isOwnName("remote-\(uuid).jpg") && ImagePaste.isOwnName("remote-\(uuid).png") && ImagePaste.isOwnName("\(uuid).png")
              && !ImagePaste.isOwnName("remote-x.jpg") && !ImagePaste.isOwnName("\(uuid).jpg") && !ImagePaste.isOwnName("notes.png")
              && !ImagePaste.isOwnName("remote-\(uuid).jpg.txt") && !ImagePaste.isOwnName("../remote-\(uuid).jpg"),
              "r3 names: only remote-<UUID>.png|jpg and <UUID>.png")
        check(ImagePaste.ownFile(mine) && !ImagePaste.ownFile(link) && !ImagePaste.ownFile(missing) && !ImagePaste.ownFile(dir.path),
              "r3 names: own file = a regular file, not a link, a folder or nothing")

        check(ImagePaste.waitsForMarker(kind: "claude") && ImagePaste.waitsForMarker(kind: "codex") && !ImagePaste.waitsForMarker(kind: "pi")
              && !ImagePaste.waitsForMarker(kind: "cursor"), "r3 marker: claude and codex show [Image #n]; others are not waited for")
        let claudeOld = "❯ look [Image #1]\n  ⎿  [Image #1]\n\n⏺ A small icon.\n\n────\n❯ \n────\n  status line"
        let claudeNew = "❯ look [Image #1]\n  ⎿  [Image #1]\n\n⏺ A small icon.\n\n────\n❯ line one\n  line two [Image #2]\n────\n  status line"
        check(ImagePaste.inputMarkers(claudeOld, kind: "claude") == 0 && ImagePaste.inputMarkers(claudeNew, kind: "claude") == 1,
              "r3 marker: claude counts only the input after its last prompt line (old markers in history do not count)")
        let codexNew = "› old one [Image #1]\n• Pesto\n› look [Image #1] [Image #2]\n  model · 94% left"
        check(ImagePaste.inputMarkers(codexNew, kind: "codex") == 2, "r3 marker: codex the same, after its last › line")
        check(ImagePaste.inputMarkers("FAKE\n[Image #1]\n", kind: "claude") == 1, "r3 marker: no prompt line -> the whole screen")
        // A long input wraps: the marker can break at its space or inside a word ("[Image" / "  #2]", seen live).
        let wrapped = "❯ old [Image #1]\n⏺ ok\n────\n❯ What single colour fills this picture? Reply with exactly: colour [Image\n  #2]\n────\n  status"
        let wrappedWord = "────\n❯ look at [Ima\n  ge #1] and [Image #2]\n────"
        let grokWrapped = "  ╭────────╮\n  │ ❯ a long line then [Image │\n  │   #2] here            │\n  ╰────────╯"
        check(ImagePaste.inputMarkers(wrapped, kind: "claude") == 1 && ImagePaste.inputMarkers(wrappedWord, kind: "claude") == 2
              && ImagePaste.inputMarkers(grokWrapped, kind: "grok") == 1,
              "r3 marker: a marker broken by the input's wrap still counts (\(ImagePaste.inputMarkers(wrapped, kind: "claude")), \(ImagePaste.inputMarkers(wrappedWord, kind: "claude")), \(ImagePaste.inputMarkers(grokWrapped, kind: "grok")))")
    }

    // (4) Disk: per device held and connection caps, output bytes counted, the cache folder capped and aged.
    do {
        let l = HubUploadLimiter()
        var holds = 0
        for _ in 0..<(HubUploadLimiter.maxHeld + 2) where l.hold(device: "d") { holds += 1 }
        check(holds == HubUploadLimiter.maxHeld, "r3 disk: \(HubUploadLimiter.maxHeld) unsent images held per device (\(holds))")
        l.release(device: "d")
        check(l.hold(device: "d") && l.held(device: "d") == HubUploadLimiter.maxHeld, "r3 disk: a release frees one")
        var conns = 0
        for _ in 0..<(HubUploadLimiter.maxConnections + 2) where l.connect(device: "d") { conns += 1 }
        check(conns == HubUploadLimiter.maxConnections, "r3 disk: \(HubUploadLimiter.maxConnections) connections per device (\(conns))")
        l.disconnect(device: "d")
        check(l.connect(device: "d") && l.connect(device: "e"), "r3 disk: a disconnect frees one; another device has its own")

        // Over sessions of one device.
        let b = FakeHubBackend(workspaces: world(.idle))
        b.screens["w1:p1"] = "> \n"
        b.imageDirectory = root.appendingPathComponent("held", isDirectory: true)
        let devices = MemoryDeviceStore()
        devices.add(token: "in", device: HubDevice(id: "d-in", name: "Phone", level: .input))
        let shared = HubUploadLimiter()
        var sessions: [HubSession] = []
        for _ in 0..<HubUploadLimiter.maxConnections {
            let s = HubSession(backend: b, devices: devices, uploads: shared)
            let h = await s.receive(msg(#"{"v":1,"type":"hello","id":"h","token":"in","client":"t","clientVersion":"1"}"#))
            if ok(h) { sessions.append(s) }
        }
        let extra = HubSession(backend: b, devices: devices, uploads: shared)
        let hx = await extra.receive(msg(#"{"v":1,"type":"hello","id":"h","token":"in","client":"t","clientVersion":"1"}"#))
        check(sessions.count == HubUploadLimiter.maxConnections && code(hx) == .rateLimited && extra.closed,
              "r3 disk: the \(HubUploadLimiter.maxConnections + 1)th connection of a device is refused (\(String(describing: code(hx))))")
        func up(_ s: HubSession, _ n: String) async -> [HubMessage] {
            await s.receive(msg(#"{"v":1,"type":"attach","id":"i","upload":"\#(n)","part":0,"parts":1,"data":"\#(png.base64EncodedString())"}"#))
        }
        for i in 0..<4 { _ = await up(sessions[0], "a\(i)"); _ = await up(sessions[1], "b\(i)") }
        let third = await up(sessions[2], "c0")
        let held = (try? FileManager.default.contentsOfDirectory(atPath: b.imageDirectory!.path))?.count ?? -1
        check(code(third) == .rateLimited && held == HubUploadLimiter.maxHeld, "r3 disk: device holds \(HubUploadLimiter.maxHeld) over its connections; more -> rateLimited (\(held) files)")
        let used = shared.used(device: "d-in")
        check(used.bytes >= 8 * png.count + 8 * 100, "r3 disk: the limiter counts the written files too (\(used.bytes) bytes for 8 images)")
        sessions[0].end()
        check(shared.held(device: "d-in") == 4, "r3 disk: ending a connection releases its held images (\(shared.held(device: "d-in")))")
        let again = HubSession(backend: b, devices: devices, uploads: shared)
        check(ok(await again.receive(msg(#"{"v":1,"type":"hello","id":"h","token":"in","client":"t","clientVersion":"1"}"#))), "r3 disk: a freed slot takes a new connection")
        for s in sessions.dropFirst() { s.end() }
        again.end()

        // The folder: only our names, oldest first, by count, bytes and age.
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let now = Date()
        var ours: [URL] = []
        for i in 0..<5 {
            let u = cache.appendingPathComponent("remote-\(UUID().uuidString).jpg")
            FileManager.default.createFile(atPath: u.path, contents: Data(count: 1000))
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(i - 10) * 60)], ofItemAtPath: u.path)
            ours.append(u)
        }
        let others = ["notes.png", "remote-evil.png", "\(UUID().uuidString).png", "keep.jpg"].map { cache.appendingPathComponent($0) }
        for u in others {
            FileManager.default.createFile(atPath: u.path, contents: Data(count: 10))
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 86_400)], ofItemAtPath: u.path)
        }
        let gone = HubImage.purge(cache, maxFiles: 3, now: now)
        check(gone == 2 && !FileManager.default.fileExists(atPath: ours[0].path) && !FileManager.default.fileExists(atPath: ours[1].path)
              && FileManager.default.fileExists(atPath: ours[4].path), "r3 disk: over the count cap the oldest hub files go (\(gone))")
        check(others.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "r3 disk: other names stay, however old")
        check(HubImage.purge(cache, maxBytes: 1500, now: now) == 2 && FileManager.default.fileExists(atPath: ours[4].path), "r3 disk: over the byte cap the oldest go")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86_400)], ofItemAtPath: ours[4].path)
        check(HubImage.purge(cache, now: now) == 1 && !FileManager.default.fileExists(atPath: ours[4].path), "r3 disk: older than 7 days goes")
    }

    // (5) The folder must be our own real folder.
    do {
        let real = root.appendingPathComponent("real", isDirectory: true), link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        var failure: HubImage.Failure?
        do { _ = try HubImage.reencode(png, into: link) } catch { failure = error as? HubImage.Failure }
        check(failure == .writeFailed && ((try? FileManager.default.contentsOfDirectory(atPath: real.path))?.isEmpty ?? false),
              "r3 folder: a symlinked folder is refused, nothing written through it")
        let open = root.appendingPathComponent("open", isDirectory: true)
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        _ = try? HubImage.reencode(png, into: open)
        let mode = (try? FileManager.default.attributesOfItem(atPath: open.path)[.posixPermissions] as? Int) ?? 0
        check(mode == 0o700, "r3 folder: an open folder is closed to 700 (\(String(mode, radix: 8)))")
        let file = root.appendingPathComponent("file")
        FileManager.default.createFile(atPath: file.path, contents: Data([1]))
        var f2: HubImage.Failure?
        do { _ = try HubImage.reencode(png, into: file) } catch { f2 = error as? HubImage.Failure }
        check(f2 == .writeFailed, "r3 folder: a file in the folder's place is refused")
    }

    // (6) Queues, the limiter before decoding, at most 2 decodes at once.
    do {
        var q = HubServer.QueueBudget()
        check(q.add(60 * 1024, paired: false) && !q.add(10 * 1024, paired: false), "r3 queue: before hello at most 64 KiB waits")
        q.done(60 * 1024)
        check(q.add(10 * 1024, paired: false) && q.queued == 10 * 1024, "r3 queue: done frees it")
        var p = HubServer.QueueBudget()
        check(p.add(4 * 1024 * 1024, paired: true) && !p.add(1, paired: true), "r3 queue: a paired connection at most 4 MiB")

        let b = FakeHubBackend(workspaces: world(.idle))
        b.imageDirectory = root.appendingPathComponent("rate", isDirectory: true)
        let devices = MemoryDeviceStore()
        devices.add(token: "in", device: HubDevice(id: "d-in", name: "Phone", level: .input))
        let l = HubUploadLimiter()
        for _ in 0..<HubUploadLimiter.maxImages { _ = l.take(device: "d-in", bytes: 1, image: true) }
        let s = HubSession(backend: b, devices: devices, uploads: l)
        _ = await s.receive(msg(#"{"v":1,"type":"hello","id":"h","token":"in","client":"t","clientVersion":"1"}"#))
        let r = await s.receive(msg(#"{"v":1,"type":"attach","id":"i","upload":"z","part":0,"parts":1,"data":"%%% not base64"}"#))
        check(code(r) == .rateLimited, "r3 queue: the rate limit is checked before decoding (\(String(describing: code(r))))")
        s.end()

        final class Gauge: @unchecked Sendable { let lock = NSLock(); var now = 0, peak = 0
            func enter() { lock.lock(); now += 1; peak = max(peak, now); lock.unlock() }
            func leave() { lock.lock(); now -= 1; lock.unlock() } }
        let g = Gauge()
        let slots = HubWorkSlots(max: 2)
        let results = await withTaskGroup(of: Int.self) { group in
            for i in 0..<6 { group.addTask { await slots.run { g.enter(); try? await Task.sleep(for: .milliseconds(40)); g.leave(); return i } } }
            var out: [Int] = []
            for await r in group { out.append(r) }
            return out
        }
        check(results.sorted() == Array(0..<6) && g.peak <= 2, "r3 queue: 6 decodes, at most 2 at once (peak \(g.peak))")
    }
}
