import Foundation
@testable import HerdrKit

// Modes that write: named test session only (never the default session). Each returns when its flag is absent, else exits.

// `HerdrKitChecks --term-live <terminal_id> <pane_id>`: real terminal control in the named session c9-input-test only.
@MainActor func modeTermLive() async throws {
    if let i = CommandLine.arguments.firstIndex(of: "--term-live") {
        let a = CommandLine.arguments
        guard a.count > i + 2 else { print("usage: --term-live <terminal_id> <pane_id>"); exit(2) }
        let tid = a[i + 1], pane = a[i + 2]
        let session = HerdrSession.named("c9-input-test")      // never the default session
        func paneText() -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["herdr", "--session", "c9-input-test", "pane", "read", pane, "--source", "recent"]
            var env = ProcessInfo.processInfo.environment; for k in env.keys where k.hasPrefix("HERDR_") { env[k] = nil }
            env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin"; p.environment = env
            let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
            try? p.run(); let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return String(decoding: d, as: UTF8.self)
        }
        final class Acc: @unchecked Sendable { let l = NSLock(); var events: [TerminalEvent] = []; var text = ""
            func add(_ e: TerminalEvent) { l.withLock { events.append(e); if case .frame(let f) = e { text += String(decoding: f.bytes, as: UTF8.self) } } }
            var snap: (events: [TerminalEvent], text: String) { l.withLock { (events, text) } } }
        func until(_ sec: Double, _ ok: () -> Bool) async -> Bool {
            let t = Date(); while Date().timeIntervalSince(t) < sec { if ok() { return true }; try? await Task.sleep(nanoseconds: 5_000_000) }; return ok()
        }
        let ts = TerminalSession(terminalId: tid, session: session, mode: .control(takeover: false), cols: 100, rows: 30)
        let acc = Acc()
        let reader = Task { for await e in ts.events { acc.add(e) } }
        let t0 = Date(); ts.start()
        let gotFirst = await until(5) { !acc.snap.events.isEmpty }
        let firstMs = Int(Date().timeIntervalSince(t0) * 1000)
        let firstFrame = acc.snap.events.compactMap { e -> TerminalFrame? in if case .frame(let f) = e { return f } else { return nil } }.first
        check(gotFirst && firstFrame?.full == true, "live: first frame is full (\(firstMs) ms, \(firstFrame?.width ?? 0)x\(firstFrame?.height ?? 0))")
        check(firstFrame?.width == 100 && firstFrame?.height == 30, "live: --cols/--rows applied at attach")

        ts.send(bytes: [0x03]); try? await Task.sleep(nanoseconds: 300_000_000)     // clear leftovers of an earlier run
        ts.send(text: "echo M$((1+2))K\r")
        check(await until(3) { acc.snap.text.contains("M3K") }, "live: typed command ran")

        // key echo latency: type x, wait for a frame with it, backspace
        var lat: [Double] = []
        for n in 0..<20 {
            let c = String(UnicodeScalar(UInt8(97 + n % 20)))
            let before = acc.snap.events.count, t = Date()
            ts.send(text: c)
            _ = await until(2) { acc.snap.events.count > before }
            lat.append(Date().timeIntervalSince(t) * 1000)
            ts.send(bytes: [0x7f])
            _ = await until(1) { acc.snap.events.count > before + 1 }
        }
        lat.sort()
        print("live: key echo latency ms median=\(Int(lat[10])) p95=\(Int(lat[18])) max=\(Int(lat[19]))")
        check(lat[10] < 100, "live: key echo median < 100 ms (\(Int(lat[10])))")

        ts.send(text: "/bin/cat -v\r")
        try? await Task.sleep(nanoseconds: 300_000_000)
        ts.send(bytes: [0x1b, 0x5b, 0x41, 0x1b, 0x78, 0x0d])       // ESC [ A, ESC x, Enter
        check(await until(3) { acc.snap.text.contains("^[[A^[x") }, "live: ESC sequences arrive intact")
        ts.send(bytes: [0x03])
        check(await until(3) { acc.snap.text.contains("^C") }, "live: Ctrl-C interrupts")

        ts.send(text: "echo 你好，世界\r")
        check(await until(3) { paneText().contains("你好，世界") }, "live: Chinese text")
        try? await Task.sleep(nanoseconds: 700_000_000)           // let zsh redraw its prompt and re-enable mode 2004
        let mark = String(Int.random(in: 1000...9999))
        ts.paste("echo pasteA\(mark)\necho pasteB\(mark)")
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(!paneText().split(separator: "\n").contains { $0 == "pasteA\(mark)" }, "live: pasted lines are not run before Enter")
        if failures > 0 { print("DEBUG pane:\n" + paneText().split(separator: "\n").suffix(12).joined(separator: "\n")) }
        ts.send(bytes: [0x0d])
        check(await until(3) { let t = paneText(); return t.contains("pasteA\(mark)") && t.contains("pasteB\(mark)") }, "live: pasted text runs after Enter")

        ts.resize(cols: 120, rows: 35)
        check(await until(3) { ts.size?.cols == 120 && ts.size?.rows == 35 }, "live: resize reflected in frames (\(ts.size?.cols ?? 0)x\(ts.size?.rows ?? 0))")
        ts.send(text: "stty size\r")
        check(await until(3) { paneText().contains("35 120") }, "live: pty size is 35 120 for the program")

        // observer next to the controller: full first frame, then increments
        let obs = TerminalSession(terminalId: tid, session: session, mode: .observe)
        let oacc = Acc()
        let oreader = Task { for await e in obs.events { oacc.add(e) } }
        obs.start()
        check(await until(3) { !oacc.snap.events.isEmpty }, "live: observer connects next to the controller")
        let om = "OBS" + String(Int.random(in: 1000...9999))
        let beforeObs = oacc.snap.events.count
        ts.send(text: "echo \(om)\r")
        check(await until(3) { oacc.snap.text.contains(om) }, "live: observer sees new output")
        _ = beforeObs
        let ofr = oacc.snap.events.compactMap { e -> TerminalFrame? in if case .frame(let f) = e { return f } else { return nil } }
        if !(ofr.first?.full == true && ofr.dropFirst().contains { !$0.full }) { print("DEBUG observer frames: " + ofr.map { "\($0.seq):\($0.full ? "F" : "i"):\($0.width)x\($0.height)" }.joined(separator: " ")) }
        check(ofr.first?.full == true && ofr.dropFirst().contains { !$0.full }, "live: observer frames: first full, then increments")
        check(!obs.send(text: "no"), "live: observer cannot send")
        obs.stop(); oreader.cancel()

        // reconnect: kill our own control process
        if let pid = ts.processIdentifier {
            let framesBefore = acc.snap.events.count
            kill(pid, SIGKILL)
            check(await until(6) { acc.snap.events.dropFirst(framesBefore).contains { if case .reconnecting = $0 { return true } else { return false } } }, "live: reconnecting after the process was killed")
            check(await until(6) { acc.snap.events.dropFirst(framesBefore).contains { if case .frame(let f) = $0 { return f.full } else { return false } } }, "live: full frame after reconnect")
            ts.send(text: "echo BACKAGAIN\r")
            check(await until(4) { paneText().contains("BACKAGAIN") }, "live: input works after reconnect")
            check(ts.size?.cols == 120, "live: size kept across reconnect (\(ts.size?.cols ?? 0))")
        } else { check(false, "live: no pid") }

        ts.release()
        check(await until(4) { acc.snap.events.contains { if case .closed(let r) = $0 { return r == "detached" } else { return false } } }, "live: release -> detached")
        reader.cancel()
        print(failures == 0 ? "LIVE OK" : "LIVE FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

// `HerdrKitChecks --scroll-live <terminal_id> <pane_id>`: scrollback paths in the named session c9-input-test only.
@MainActor func modeScrollLive() async throws {
    if let i = CommandLine.arguments.firstIndex(of: "--scroll-live") {
        let a = CommandLine.arguments
        guard a.count > i + 2 else { print("usage: --scroll-live <terminal_id> <pane_id>"); exit(2) }
        let tid = a[i + 1], pane = a[i + 2]
        let session = HerdrSession.named("c9-input-test")      // never the default session
        let client = HerdrClient(session: session)
        func until(_ sec: Double, _ ok: () async -> Bool) async -> Bool {
            let t = Date(); while Date().timeIntervalSince(t) < sec { if await ok() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }; return await ok()
        }
        let ts = TerminalSession(terminalId: tid, session: session, mode: .control(takeover: true))
        ts.start()
        _ = await until(3) { ts.size != nil }
        ts.send(bytes: [0x03, 0x15]); try? await Task.sleep(nanoseconds: 300_000_000)
        let tag = String(Int.random(in: 1000...9999))
        ts.send(text: "clear; seq 1 3000; printf '\\033[31mRED\(tag)\\033[0m\\n'\r")
        check(await until(8) { (try? await client.readScrollback(paneId: pane, lines: 10_000).text.contains("RED\(tag)\u{1b}[0m")) == true }, "scroll-live: command output is in the history")

        let sbk = try await client.readScrollback(paneId: pane, lines: 10_000)
        let nums = sbk.text.split(whereSeparator: \.isNewline).compactMap { Int($0) }
        check(sbk.truncated && sbk.lineCount <= Scrollback.readLimit + 1 && nums.contains(3000), "scroll-live: one read gives the last ~1000 lines and says truncated (\(sbk.lineCount))")
        let redLine = sbk.text.components(separatedBy: "\r\n").first { $0.contains("RED\(tag)") && !$0.contains("printf") } ?? ""
        if !(redLine.contains("\u{1b}[") && redLine.contains("RED\(tag)")) { print("DEBUG red line: \(redLine.debugDescription)") }
        check(redLine.contains("\u{1b}[") && redLine.contains("RED\(tag)"), "scroll-live: ANSI colors are kept")
        let deep = try await client.readDeepHistory(paneId: pane, lines: 10_000, ansi: false)
        let dn = deep.text.split(whereSeparator: \.isNewline).compactMap { Int($0) }
        if dn != Array(1...3000) { print("DEBUG deep missing: \(Array(Set(1...3000).subtracting(dn)).sorted().prefix(10)) first=\(dn.first ?? -1) last=\(dn.last ?? -1)") }
        check(dn.first == 1 && dn.last == 3000 && dn == Array(1...3000), "scroll-live: deep history is 1...3000 in order, no gaps or repeats (\(dn.count) numbers)")
        check((try await client.scrollInfo(paneId: pane)).offsetFromBottom == 0, "scroll-live: deep read restores the scroll position")
        let limited = try await client.readScrollback(paneId: pane, lines: 200)
        check(limited.lineCount <= 205 && limited.lineCount >= 150, "scroll-live: lines limit (\(limited.lineCount))")
        let plain = try await client.readScrollback(paneId: pane, lines: 200, ansi: false)
        check(!plain.text.contains("\u{1b}") && plain.text.contains("RED\(tag)"), "scroll-live: plain text mode")

        let info = try await client.scrollInfo(paneId: pane)
        check(info.kind == .history && info.maxOffsetFromBottom > 2000 && info.shellIsForeground == true, "scroll-live: shell with history (\(info.maxOffsetFromBottom) lines)")

        // Reading must not change the pane: no input, no scroll offset change, same screen.
        let screen0 = try await client.readScrollback(paneId: pane, lines: 40, ansi: false).text
        for _ in 0..<5 { _ = try await client.readScrollback(paneId: pane, lines: 5000) }
        let screen1 = try await client.readScrollback(paneId: pane, lines: 40, ansi: false).text
        let info2 = try await client.scrollInfo(paneId: pane)
        check(screen0 == screen1 && info2.offsetFromBottom == 0, "scroll-live: reading history changes nothing in the pane")

        // Observer-only scrolling path: set the shared offset through the socket, no controller needed
        ts.release(); try? await Task.sleep(nanoseconds: 500_000_000)
        let obs = TerminalSession(terminalId: tid, session: session, mode: .observe)
        final class Fr: @unchecked Sendable { let l = NSLock(); var t = ""; func add(_ s: String) { l.withLock { t += s } }; var text: String { l.withLock { t } } }
        let fr = Fr()
        let rd = Task { for await e in obs.events { if case .frame(let f) = e { fr.add(String(decoding: f.bytes, as: UTF8.self)) } } }
        obs.start()
        _ = await until(3) { !fr.text.isEmpty }
        try await client.setScrollOffset(paneId: pane, fromBottom: 1500)
        let moved = await until(3) { (try? await client.scrollInfo(paneId: pane))?.offsetFromBottom == 1500 }
        check(moved, "scroll-live: setScrollOffset moves the viewport")
        check(await until(3) { fr.text.contains("14") }, "scroll-live: observer frames follow")
        try await client.setScrollOffset(paneId: pane, fromBottom: 0)
        check(await until(3) { (try? await client.scrollInfo(paneId: pane))?.offsetFromBottom == 0 }, "scroll-live: offset back to bottom")
        obs.stop(); rd.cancel()

        // full-screen program: no history, foreground is not the shell
        let ts2 = TerminalSession(terminalId: tid, session: session, mode: .control(takeover: true))
        ts2.start(); _ = await until(3) { ts2.size != nil }
        ts2.send(text: "seq 1 400 > /tmp/hk-seq.txt; command less /tmp/hk-seq.txt\r")
        check(await until(5) { (try? await client.scrollInfo(paneId: pane))?.kind == .fullScreenProgram }, "scroll-live: less -> .fullScreenProgram")
        ts2.send(text: "q")
        check(await until(5) { (try? await client.scrollInfo(paneId: pane))?.kind == .history }, "scroll-live: back to .history after q")
        ts2.release()
        print(failures == 0 ? "SCROLL LIVE OK" : "SCROLL LIVE FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

// `HerdrKitChecks --wheel-live <terminal_id> <pane_id>`: how herdr routes a wheel step, in c9-input-test only.
@MainActor func modeWheelLive() async throws {
    if let i = CommandLine.arguments.firstIndex(of: "--wheel-live") {
        let a = CommandLine.arguments
        guard a.count > i + 2 else { print("usage: --wheel-live <terminal_id> <pane_id>"); exit(2) }
        let tid = a[i + 1], pane = a[i + 2]
        let session = HerdrSession.named("c9-input-test")      // never the default session
        let client = HerdrClient(session: session)
        func until(_ sec: Double, _ ok: () async -> Bool) async -> Bool {
            let t = Date(); while Date().timeIntervalSince(t) < sec { if await ok() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }; return await ok()
        }
        func screen() async -> String { ((try? await client.readScrollback(paneId: pane, lines: 40, ansi: false).text) ?? "") }
        let ts = TerminalSession(terminalId: tid, session: session, mode: .control(takeover: true))
        ts.start(); _ = await until(3) { ts.size != nil }
        func reset() async {
            ts.send(bytes: [0x03]); try? await Task.sleep(nanoseconds: 300_000_000)
            ts.send(text: "printf '\\033[?1000l\\033[?1003l\\033[?1006l\\033[?1007l\\033[?1049l'; clear\r"); try? await Task.sleep(nanoseconds: 500_000_000)
        }
        func probe(_ modes: String) async -> String {
            await reset()
            ts.send(text: "printf '\\033[?1049h\(modes)'; /bin/cat -v\r"); try? await Task.sleep(nanoseconds: 700_000_000)
            ts.wheel(lines: 3, up: true)
            try? await Task.sleep(nanoseconds: 700_000_000)
            let up = await screen()
            ts.wheel(lines: 2, up: false, eventPerLine: true)
            try? await Task.sleep(nanoseconds: 700_000_000)
            return await screen() + "\u{0}" + up
        }
        let mouse = await probe("\\033[?1000h\\033[?1006h")
        let upPart = mouse.components(separatedBy: "\u{0}").last ?? ""
        check(upPart.contains("^[[<64;1;1M"), "wheel-live: mouse tracking (1000+1006): SGR wheel-up reaches the program")
        check(mouse.contains("^[[<65;1;1M^[[<65;1;1M"), "wheel-live: eventPerLine sends one wheel-down event per line")
        let legacy = await probe("\\033[?1000h")
        check(legacy.contains("^[[M`"), "wheel-live: mouse tracking without SGR: legacy encoding")
        let alt = await probe("\\033[?1007h")
        check(alt.contains("^[[A"), "wheel-live: alternate scroll (1007): arrow keys")
        let none = await probe("")
        check(!none.contains("^[["), "wheel-live: alternate screen without mouse or 1007: nothing is sent")

        // main screen: the wheel scrolls herdr's history, the program gets nothing
        await reset()
        ts.send(text: "seq 1 300\r"); try? await Task.sleep(nanoseconds: 800_000_000)
        ts.wheel(lines: 10, up: true)
        check(await until(3) { (try? await client.scrollInfo(paneId: pane))?.offsetFromBottom == 10 }, "wheel-live: main screen: wheel moves herdr's scroll position by `lines`")
        ts.wheel(lines: 10, up: false)
        check(await until(3) { (try? await client.scrollInfo(paneId: pane))?.offsetFromBottom == 0 }, "wheel-live: wheel down returns to the bottom")
        await reset()

        let obs = TerminalSession(terminalId: tid, session: session, mode: .observe)
        check(!obs.wheel(lines: 1, up: true), "wheel-live: observe mode cannot wheel")
        ts.release()
        print(failures == 0 ? "WHEEL LIVE OK" : "WHEEL LIVE FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

// `HerdrKitChecks --tabmove-live`: moveTab in c9-input-test only, in its own throwaway workspace.
@MainActor func modeTabmoveLive() async throws {
    if CommandLine.arguments.contains("--tabmove-live") {
        let client = HerdrClient(session: HerdrSession.named("c9-input-test"))      // never the default session
        func tabs(_ ws: String) async -> [String] { ((try? await client.snapshot()) ?? []).first { $0.id == ws }?.tabs.map(\.id) ?? [] }
        let ws = try await client.createWorkspace(label: "hk-move", cwd: "/tmp")
        for l in ["b", "c"] { try await client.createTab(workspaceId: ws, label: l) }
        let t0 = await tabs(ws)
        check(t0.count == 3, "tabmove-live: 3 tabs (\(t0))")
        try await client.moveTab(t0[0], toIndex: 2)
        let t1 = await tabs(ws)
        check(t1 == [t0[1], t0[2], t0[0]], "tabmove-live: first to index 2 -> \(t1)")
        try await client.moveTab(t0[0], toIndex: 0)
        check(await tabs(ws) == t0, "tabmove-live: back to index 0")
        try await client.moveTab(t0[2], toIndex: 1)
        check(await tabs(ws) == [t0[0], t0[2], t0[1]], "tabmove-live: last to index 1")
        do { try await client.moveTab("w99:t1", toIndex: 0); check(false, "tabmove-live: missing tab fails") } catch { check(true, "tabmove-live: missing tab fails") }
        try await client.closeWorkspace(id: ws)
        print(failures == 0 ? "tabmove-live OK" : "tabmove-live FAILED"); exit(failures == 0 ? 0 : 1)
    }
}

// `HerdrKitChecks --question-live`: end-to-end question answer in c9-input-test only.
// PANE: an agent pane there; LOG: its session log; PROMPT: text that makes the agent ask; ANSWERS: JSON [{"picks":[0],"other":"x"}];
// EXPECT: JSON array of the answers the log must report. Never the default session.
@MainActor func modeQuestionLive() async throws {
    if CommandLine.arguments.contains("--question-live") {
        let env = ProcessInfo.processInfo.environment
        guard let pane = env["PANE"], let log = env["LOG"], let ans = env["ANSWERS"]?.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: ans) as? [[String: Any]] else { print("need PANE LOG ANSWERS"); exit(2) }
        let client = HerdrClient(session: HerdrSession.named("c9-input-test"))      // never the default session
        let answers = raw.map { QuestionAnswer(picks: $0["picks"] as? [Int] ?? [], other: $0["other"] as? String) }
        func lastQuestion() -> QuestionRequest? {
            let lines = (try? String(contentsOfFile: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            for item in SessionLog.parse(lines: lines).reversed() { if case .question(let q) = item.kind { return q } }
            return nil
        }
        let before = lastQuestion()?.toolUseId
        // Safety: no picker on screen -> nothing is sent.
        let fake = QuestionRequest(toolUseId: "x", agent: env["AGENT"] ?? "claude", questions: [.init(header: "x", text: "Not on screen at all?", options: [.init(label: "a")])])
        do { try await client.answerQuestion(paneId: pane, request: fake, answers: [QuestionAnswer(picks: [0])]); check(false, "question-live: not on screen throws") }
        catch let e as QuestionAdapter.Failure { check(e == .notOnScreen, "question-live: not on screen throws (\(e))") }
        if let prompt = env["PROMPT"] { try await client.send(text: prompt, to: pane) }
        var q: QuestionRequest?
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 40 {
            if (env["AGENT"] ?? "claude") == "claude" {   // Claude logs the call only after the answer: read the screen
                let s0 = try await client.visibleText(paneId: pane)
                if var l = try await client.pendingQuestion(paneId: pane) {
                    try await Task.sleep(for: .milliseconds(300))
                    let s1 = try await client.visibleText(paneId: pane)
                    check(s0 == s1 && l.questions.count == 1 && l.headers.count >= 1, "question-live: read-only read sends nothing (screen unchanged), unread=\(l.unread)")
                    if l.unread > 0 {
                        do { try await client.answerQuestion(paneId: pane, request: l, answers: l.headers.map { _ in QuestionAnswer(picks: [0]) }); check(false, "question-live: unread>0 refused") }
                        catch let e as QuestionAdapter.Failure {
                            let s2 = try await client.visibleText(paneId: pane)
                            check(s2 == s0, "question-live: answer with unread>0 refused before sending (\(e))")
                        }
                        guard let full = try await client.loadAllQuestions(paneId: pane) else { check(false, "question-live: loadAllQuestions nil"); break }
                        let s2 = try await client.visibleText(paneId: pane)
                        check(full.unread == 0 && full.toolUseId == l.toolUseId && QuestionAdapter.claudeScreen(s2)?.question.text == QuestionAdapter.claudeScreen(s0)?.question.text,
                              "question-live: loadAllQuestions read \(full.questions.count) and moved back")
                        l = full
                    }
                    q = l; break
                }
            } else if let l = lastQuestion(), l.toolUseId != before || env["PROMPT"] == nil, l.state == .pending {
                let screen = (try? await client.visibleText(paneId: pane)) ?? ""
                if l.delivery == .message || QuestionAdapter.screenShows(l, screen: screen) { q = l; break }
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        guard let q else { check(false, "question-live: no pending question on screen in 40 s"); exit(1) }
        print("question-live: asked \(q.questions.map { "\($0.header): \($0.text) \($0.options.map(\.label))\($0.multiSelect ? " multi" : "")" }) after \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        let t1 = Date()
        do { try await client.answerQuestion(paneId: pane, request: q, answers: answers); check(true, "question-live: answered in \(Int(Date().timeIntervalSince(t1) * 1000)) ms") }
        catch { check(false, "question-live: answerQuestion threw \(error)") }
        var state = q.state
        let t2 = Date()
        while Date().timeIntervalSince(t2) < 15, state == .pending {
            try await Task.sleep(for: .milliseconds(300))
            if let l = lastQuestion(), l.toolUseId == q.toolUseId || (l.toolUseId != before && l.questions.map(\.text) == q.questions.map(\.text)) { state = l.state }
        }
        let expect = env["EXPECT"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] }
        check(expect.map { state == .answered($0) } ?? (state != .pending), "question-live: log reports \(state)")
        print(failures == 0 ? "question-live OK" : "question-live FAILED"); exit(failures == 0 ? 0 : 1)
    }
}

// `HerdrKitChecks --ws-live`: workspace create/rename/focus/close in c9-input-test only; creates and closes its own workspace.
@MainActor func modeWsLive() async throws {
    if CommandLine.arguments.contains("--ws-live") {
        let client = HerdrClient(session: HerdrSession.named("c9-input-test"))      // never the default session
        func wss() async -> [Workspace] { (try? await client.snapshot()) ?? [] }
        func until(_ sec: Double, _ ok: () async -> Bool) async -> Bool {
            let t = Date(); while Date().timeIntervalSince(t) < sec { if await ok() { return true }; try? await Task.sleep(nanoseconds: 30_000_000) }; return await ok()
        }
        let id = try await client.createWorkspace(label: "hk-ws", cwd: "/tmp")
        check(id.hasPrefix("w"), "ws-live: createWorkspace returns an id (\(id))")
        check(await until(3) { await wss().first { $0.id == id }?.label == "hk-ws" }, "ws-live: new workspace has the label")
        let w = await wss().first { $0.id == id }
        check(w?.tabs.count == 1 && w?.tabs.first?.panes.count == 1, "ws-live: one tab with one pane")
        check(w?.tabs.first?.panes.first?.cwd.hasSuffix("tmp") == true, "ws-live: pane cwd follows cwd")
        try await client.renameWorkspace(id: id, to: "hk-ws2")
        check(await until(3) { await wss().first { $0.id == id }?.label == "hk-ws2" }, "ws-live: renameWorkspace")
        try await client.focusWorkspace(id: id)
        check(true, "ws-live: focusWorkspace accepted")
        try await client.closeWorkspace(id: id)
        check(await until(3) { await wss().first { $0.id == id } == nil }, "ws-live: closeWorkspace removes it")
        do { try await client.closeWorkspace(id: id); check(false, "ws-live: closing again fails") } catch { check(true, "ws-live: closing again fails") }
        do { try await client.renameWorkspace(id: "w99", to: "x"); check(false, "ws-live: rename missing fails") } catch { check(true, "ws-live: rename missing fails") }
        print(failures == 0 ? "ws-live OK" : "ws-live FAILED"); exit(failures == 0 ? 0 : 1)
    }
}

// `HerdrKitChecks --pane-live <terminal_id> <pane_id>`: pane menu operations in c9-input-test only. Splits <pane_id> once and closes the new pane.
@MainActor func modePaneLive() async throws {
    if let i = CommandLine.arguments.firstIndex(of: "--pane-live") {
        let a = CommandLine.arguments
        guard a.count > i + 2 else { print("usage: --pane-live <terminal_id> <pane_id>"); exit(2) }
        let tid = a[i + 1], base = a[i + 2]
        let session = HerdrSession.named("c9-input-test")      // never the default session
        let client = HerdrClient(session: session)
        func until(_ sec: Double, _ ok: () async -> Bool) async -> Bool {
            let t = Date(); while Date().timeIntervalSince(t) < sec { if await ok() { return true }; try? await Task.sleep(nanoseconds: 30_000_000) }; return await ok()
        }
        func panes() async -> [Pane] { ((try? await client.snapshot()) ?? []).flatMap(\.tabs).flatMap(\.panes) }
        let before = Set(await panes().map(\.id))
        try await client.split(paneId: base, direction: .right)
        guard let newPane = await panes().first(where: { !before.contains($0.id) }) else { check(false, "pane-live: split made a new pane"); exit(1) }
        check(true, "pane-live: split made \(newPane.id)")

        try await client.renamePane(paneId: newPane.id, to: "hk-menu")
        check(await until(3) { await panes().first { $0.id == newPane.id }?.label == "hk-menu" }, "pane-live: renamePane shows in the snapshot")
        try await client.renamePane(paneId: newPane.id, to: nil)
        check(await until(3) { await panes().first { $0.id == newPane.id }?.label == nil }, "pane-live: renamePane(nil) clears the label")
        try await client.renamePane(paneId: newPane.id, to: "")
        check(await panes().first { $0.id == newPane.id }?.label == nil, "pane-live: empty label clears too")

        try await client.setRightClickRouting(paneId: newPane.id, to: .pane)
        try await client.setRightClickRouting(paneId: newPane.id, to: .herdr)
        check(true, "pane-live: setRightClickRouting accepted for pane and herdr")
        do { try await client.setRightClickRouting(paneId: "w99:p99", to: .pane); check(false, "pane-live: routing on a missing pane fails") }
        catch { check(true, "pane-live: routing on a missing pane fails") }

        // right click reaches a program that tracks the mouse (SGR and legacy), via the controller
        let ts = TerminalSession(terminalId: newPane.terminalId, session: session, mode: .control(takeover: true))
        ts.start(); _ = await until(3) { ts.size != nil }
        func screen() async -> String { ((try? await client.readScrollback(paneId: newPane.id, lines: 40, ansi: false).text) ?? "") }
        ts.send(text: "printf '\\033[?1000h\\033[?1006h'; /bin/cat -v\r"); try? await Task.sleep(nanoseconds: 700_000_000)
        ts.rightClick(col: 12, row: 7)
        check(await until(3) { await screen().contains("^[[<2;12;7M^[[<2;12;7m") }, "pane-live: SGR right click (12,7) reaches the program")
        ts.send(bytes: [0x03]); try? await Task.sleep(nanoseconds: 300_000_000)
        ts.send(text: "printf '\\033[?1006l'; /bin/cat -v\r"); try? await Task.sleep(nanoseconds: 700_000_000)
        ts.rightClick(col: 12, row: 7, encoding: .legacy)
        check(await until(3) { await screen().contains("^[[M\",'") }, "pane-live: legacy right click reaches the program")
        ts.send(bytes: [0x03]); try? await Task.sleep(nanoseconds: 300_000_000)
        ts.release()

        try await client.closePane(paneId: newPane.id)
        check(await until(3) { await !panes().contains { $0.id == newPane.id } }, "pane-live: closePane removes the pane")
        do { try await client.closePane(paneId: newPane.id); check(false, "pane-live: closing a closed pane fails") }
        catch { check(true, "pane-live: closing a closed pane fails") }
        check(await panes().contains { $0.id == base }, "pane-live: the other pane is still there")
        print(failures == 0 ? "PANE LIVE OK" : "PANE LIVE FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

// `HerdrKitChecks --live [session]` prints the live tree (read-only snapshot) instead of running the checks.
@MainActor func modeLive() async throws {
    if CommandLine.arguments.contains("--live") {
        let name = CommandLine.arguments.drop { $0 != "--live" }.dropFirst().first
        let session = name.map(HerdrSession.named) ?? .default()
        let tree = try await HerdrClient(session: session).snapshot()
        for w in tree {
            print("\(w.label) [\(w.id)]")
            for t in w.tabs { print("  \(t.number) \(t.label) \(t.status.rawValue) panes=\(t.panes.count) agents=\(t.panes.compactMap { $0.agent?.name }.joined(separator: ","))") }
        }
        exit(0)
    }
}

// `HerdrKitChecks --send <named-session> <pane> <text>`: types text + Enter through HerdrClient. Refuses the default session.
@MainActor func modeSend() async throws {
    if let i = CommandLine.arguments.firstIndex(of: "--send") {
        let a = CommandLine.arguments
        guard a.count > i + 3, a[i + 1] != "default", !a[i + 1].isEmpty else { print("usage: --send <named-session> <pane> <text>"); exit(2) }
        let client = HerdrClient(session: .named(a[i + 1]))
        try await client.send(text: a[i + 3], to: a[i + 2])
        print("sent")
        exit(0)
    }
}

// `HerdrKitChecks --ready <session> <pane>...`: the remote send gate (`readyForText`) on live panes. Read-only.
@MainActor func modeReady() async throws {
    if let i = CommandLine.arguments.firstIndex(of: "--ready") {
        let a = CommandLine.arguments
        guard a.count > i + 2 else { print("usage: --ready <session> <pane>..."); exit(2) }
        let client = HerdrClient(session: .named(a[i + 1]))
        let panes = ((try? await client.snapshot()) ?? []).flatMap(\.tabs).flatMap(\.panes)
        for id in a[(i + 2)...] {
            let agent = panes.first { $0.id == id }?.agent
            print("\(id) agent=\(agent?.kind ?? "none") status=\(agent?.status.rawValue ?? "-") picker=\(Hub.screenTakesKeys((try? await client.visibleText(paneId: id)) ?? "")) ready=\(await client.readyForText(paneId: id))")
        }
        exit(0)
    }
}

@MainActor func modeKeys() async throws {
    if let i = CommandLine.arguments.firstIndex(of: "--keys") {
        let a = CommandLine.arguments
        guard a.count > i + 3, a[i + 1] != "default" else { print("usage: --keys <named-session> <pane> <key>..."); exit(2) }
        try await HerdrClient(session: .named(a[i + 1])).sendNamedKeys(Array(a[(i + 3)...]), to: a[i + 2])
        print("sent keys")
        exit(0)
    }
}

// `HerdrKitChecks --layout <named-session> <workspace>`: create, rename, split, close a tab through HerdrClient. Refuses default.
@MainActor func modeLayout() async throws {
    if let i = CommandLine.arguments.firstIndex(of: "--layout") {
        let a = CommandLine.arguments
        guard a.count > i + 2, a[i + 1] != "default" else { print("usage: --layout <named-session> <workspace>"); exit(2) }
        let c = HerdrClient(session: .named(a[i + 1])), wsId = a[i + 2]
        func tabs() async throws -> [Tab] { try await c.snapshot().first { $0.id == wsId }?.tabs ?? [] }
        let before = Set(try await tabs().map(\.id))
        try await c.createTab(workspaceId: wsId, label: "hk-layout")
        let created = try await tabs().first { !before.contains($0.id) }
        check(created?.label == "hk-layout", "layout: createTab")
        guard let tab = created else { print("FAIL no tab"); exit(1) }
        try await c.renameTab(tab.id, to: "hk-renamed")
        check(try await tabs().first { $0.id == tab.id }?.label == "hk-renamed", "layout: renameTab")
        try await c.split(paneId: tab.panes[0].id, direction: .right)
        check(try await tabs().first { $0.id == tab.id }?.panes.count == 2, "layout: split")
        try await c.closeTab(tab.id)
        check(!(try await tabs().contains { $0.id == tab.id }), "layout: closeTab")
        print(failures == 0 ? "OK layout \(total) checks" : "FAILED \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
