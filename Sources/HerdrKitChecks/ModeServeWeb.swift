import Foundation
import ImageIO
@testable import HerdrKit

/// `--serve-web`: a hub with the bundled PWA and a fake backend, for the headless browser test (scripts/web-test.mjs).
/// TLS with a throwaway self-signed certificate, 127.0.0.1 only, never herdr. Prints one JSON line
/// (port, cert path, tokens), then serves until stdin closes. Input changes the fake state the way an agent would.
/// Lines on stdin change it too: `grow <session> <n>` appends n long replies (an agent writing while the page is open);
/// `session <pane> <session> [rows]` puts another session in a pane (40 rows unless given); `pictures <pane> <session>`
/// puts a session whose log has pictures in a pane (the owner's message with two, a Read result with one, 40 lines after).
@MainActor func modeServeWeb() async throws {
    guard CommandLine.arguments.contains("--serve-web") else { return }
    let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "hkweb-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    func agent(_ s: AgentStatus, _ id: String, _ title: String, kind: String = "claude") -> Agent { Agent(name: kind, kind: kind, status: s, sessionId: id, title: title) }
    func pane(_ id: String, _ a: Agent?) -> Pane { Pane(id: id, terminalId: "term_" + id, cwd: "/work/site", agent: a) }
    var ws = [
        Workspace(id: "w1", label: "site", tabs: [
            Tab(id: "w1:t1", label: "build", number: 1, panes: [pane("w1:p1", agent(.blocked, "s1", "Fix the build"))], status: .blocked),
            Tab(id: "w1:t2", label: "deploy", number: 2, panes: [pane("w1:p2", agent(.blocked, "s2", "Deploy target", kind: "codex"))], status: .blocked),
        ]),
        Workspace(id: "w2", label: "api", tabs: [
            Tab(id: "w2:t1", label: "tests", number: 1, panes: [pane("w2:p1", agent(.working, "s3", "Add tests", kind: "codex"))], status: .working),
            Tab(id: "w2:t2", label: "notes", number: 2, panes: [pane("w2:p2", agent(.idle, "s4", "Notes")), pane("w2:p3", nil)], status: .idle),
        ]),
    ]
    let b = FakeHubBackend(workspaces: ws)
    b.sessionName = nil
    b.imageDirectory = dir.appendingPathComponent("images", isDirectory: true)
    let chip = ToolChip(symbol: "terminal", text: "Ran 2 commands", calls: [
        ToolCall(id: "c1", toolName: "Bash", summary: "npm test", input: "{\"command\":\"npm test\"}", output: "3 passed"),
        ToolCall(id: "c2", toolName: "Bash", summary: "npm run lint", input: "{\"command\":\"npm run lint\"}", output: "ok"),
    ])
    b.earlier["s1"] = (0..<3).map { ConversationItem(id: "e\($0)", kind: .assistantText("Older message \($0 + 1).")) }
    b.items["s1"] = [
        ConversationItem(id: "a1", kind: .userText("The build fails on main. Please fix it.")),
        ConversationItem(id: "a2", kind: .assistantText("The type check fails in **src/app.ts**. I will run the build:\n\n```\nnpm run build\n```")),
        ConversationItem(id: "a3", kind: .toolChips([chip])),
        ConversationItem(id: "a4", kind: .permissionRequest(PermissionRequest(title: "Bash command", command: "npm run build", toolName: "Bash", toolUseId: "tu1"))),
    ]
    b.screens["w1:p1"] = """
    ────────────────────────────────────────
     Bash command
     Build it
    ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
     npm run build
    ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
     Do you want to proceed?
     ❯ 1. Yes
       2. No

     Esc to cancel · Tab to amend
    """
    // A Codex question from its log: the phone may answer it. (A Claude one, read from the screen, is for the Mac: "ask me".)
    let q = QuestionRequest(toolUseId: "tq1", agent: "codex", questions: [.init(header: "Target", text: "Which target?",
                            options: [.init(label: "Staging", detail: "The test site", recommended: true), .init(label: "Production")])])
    b.items["s2"] = [ConversationItem(id: "b1", kind: .userText("Deploy it.")), ConversationItem(id: "b2", kind: .question(q))]
    b.screens["w1:p2"] = """
      Question 1/1 (1 unanswered)
      Which target?

      › 1. Staging (Recommended)  The test site
        2. Production
        3. None of the above      Optionally, add details in notes (tab)

      tab to add notes | enter to submit answer | esc to interrupt
    """
    let claudePicker = """
     ←  ☐ Target  ✔ Submit  →

    Which target?

    ❯ 1. Staging
      2. Production
      3. Type something.
    ──────────────────────────
      Chat about this
    """
    b.items["s3"] = [ConversationItem(id: "c1", kind: .userText("Add tests for the parser.")), ConversationItem(id: "c2", kind: .assistantText("Working on it."))]
    b.screens["w2:p1"] = "• Working (12s • esc to interrupt)"
    b.items["s4"] = [ConversationItem(id: "d1", kind: .assistantText("Notes are up to date."))]
    b.screens["w2:p2"] = "> "
    b.screens["w2:p3"] = "$ "

    let devices = MemoryDeviceStore()
    devices.add(token: "read-token", device: HubDevice(id: "d-read", name: "Read phone", level: .read))
    devices.add(token: "input-token", device: HubDevice(id: "d-input", name: "Input phone", level: .input))
    let pairing = HubPairing(devices: devices)
    let offer = pairing.offer()
    let id = try HubTLS.selfSigned(in: dir, names: ["127.0.0.1"])
    let server = HubServer(backend: b, devices: devices, pairing: pairing, tickInterval: .milliseconds(250))
    let port = try await server.start(host: "127.0.0.1", port: 0, tls: id)
    let info: [String: Any] = ["port": Int(port), "cert": dir.appendingPathComponent("cert.pem").path, "fingerprint": id.fingerprint,
                               "pairSecret": offer.secret, "pairCode": offer.code]
    print(String(decoding: try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]), as: UTF8.self))
    fflush(stdout)

    // Input moves the fake agents on, as herdr would: allow -> working; answer/send -> a new user line.
    var seen = (0, 0, 0), seenImages = 0, seenPulls = 0
    // A working Claude with two queued messages (its own queue, read from the screen): "queue me", "queue busy", "queue stop".
    let rule = String(repeating: "─", count: 40)
    func queueScreen(input: String = "❯ Press up to edit queued messages") -> String {
        ["⏺ Working on the notes", "❯ Also run the lint step before you commit.", "❯ Then open a draft PR with a short summary.",
         "  ctrl+enter to send now", "· Baking… (12s)", rule, input, rule].joined(separator: "\n")
    }
    let pulledText = "Also run the lint step before you commit.\nThen open a draft PR with a short summary."
    // "compact me": the Claude agent on w2:p2 compacts its context; its screen changes on every pass, as the timer does.
    var compacting = 0
    func setStatus(_ pane: String, _ s: AgentStatus) {
        for wi in ws.indices { for ti in ws[wi].tabs.indices { for pi in ws[wi].tabs[ti].panes.indices where ws[wi].tabs[ti].panes[pi].id == pane {
            ws[wi].tabs[ti].panes[pi].agent?.status = s; ws[wi].tabs[ti].status = s
        } } }
        b.workspaces = ws
    }
    while true {
        // A pull that took the text takes the queue off the agent's screen (before new input, which may set another
        // screen); a refused one leaves it.
        if b.pulls.count > seenPulls {
            seenPulls = b.pulls.count
            if b.pullOutcome.text != nil { b.screens["w2:p2"] = "⏺ Working on the notes\n" + rule + "\n❯ \n" + rule }
        }
        let now = (b.approved.count, b.answered.count, b.sent.count)
        if now.0 > seen.0, let last = b.approved.last {
            let pane = String(last.split(separator: " ")[0]), allow = last.hasSuffix("true")
            b.screens[pane] = allow ? "• Running npm run build" : "> "
            b.items["s1"] = (b.items["s1"] ?? []).map { i in
                if case .permissionRequest(var p) = i.kind { p.state = .resolved; return ConversationItem(id: i.id, kind: .permissionRequest(p)) }
                return i
            } + [ConversationItem(id: "a5", kind: .assistantText(allow ? "Build passed." : "OK, I will not run it."))]
            setStatus(pane, allow ? .working : .idle)
        }
        if now.1 > seen.1 {
            b.screens["w1:p2"] = "> "
            b.items["s2"]?.append(ConversationItem(id: "b3", kind: .assistantText("Deploying to the chosen target.")))
            setStatus("w1:p2", .working)
        }
        if now.2 > seen.2, let last = b.sent.last {
            let pane = String(last.split(separator: " ")[0])
            var text = String(last.drop(while: { $0 != " " }).dropFirst())
            // Images: the count and their size, as the agent would see them.
            if b.sentImages.count > seenImages, let imgs = b.sentImages.last {
                seenImages = b.sentImages.count
                let sizes = imgs.map { u in
                    let p = imageProperties(u)
                    return "\(p[kCGImagePropertyPixelWidth as String] as? Int ?? 0)x\(p[kCGImagePropertyPixelHeight as String] as? Int ?? 0)"
                }
                text = ([text] + ["[\(imgs.count) image\(imgs.count == 1 ? "" : "s") \(sizes.joined(separator: " "))]"]).filter { !$0.isEmpty }.joined(separator: " ")
            }
            let sid = ws.flatMap(\.tabs).flatMap(\.panes).first { $0.id == pane }?.agent?.sessionId ?? ""
            b.items[sid, default: []].append(ConversationItem(id: "u\(now.2)", kind: .userText(text)))
            // "block me": another agent starts to wait (the PWA's in-app alert).
            if text == "block me" { b.screens["w2:p1"] = "Waiting for you"; setStatus("w2:p1", .blocked) }
            // "queued log": the conversation of a Claude log with messages it took mid-turn (Fixtures/queued.jsonl).
            if text == "queued log" {
                let lines = String(decoding: fixture("queued.jsonl"), as: UTF8.self).split(separator: "\n").map(String.init)
                b.items[sid, default: []] += SessionLog.parse(lines: lines)
            }
            // "status me": Claude Code's status line for this session (as the wrapper saves it); "status off": none.
            if text == "status me" {
                let e = "\u{1B}"
                let line = "\(e)[38;5;141mOpus 5.5\(e)[0m \(e)[2m·\(e)[0m \(e)[36m⎇ main\(e)[0m \(e)[2m·\(e)[0m ctx \(e)[33m42%\(e)[0m \(e)[2m·\(e)[0m turn \(e)[32m$0.18\(e)[0m "
                    + "\(e)[2m·\(e)[0m session \(e)[32m$3.27\(e)[0m \(e)[2m·\(e)[0m day \(e)[1m$11.40\(e)[0m/$25 \(e)[2m·\(e)[0m month \(e)[1;31m$212\(e)[0m/$300\n\(e)[2mrate limit 5h: 23%\(e)[0m"
                let info = ClaudeStatusInfo(json: Data(#"{"session_id":"s-web","model":{"display_name":"Opus 5.5"},"cost":{"total_cost_usd":3.274},"context_window":{"context_window_size":1000000,"used_percentage":41.6}}"#.utf8))
                b.statusLines[sid] = StatusLineRecord(lines: ANSIText.lines(line), info: info, time: Date())
            }
            if text == "status off" { b.statusLines[sid] = nil }
            // "long history": 350 older rows in front of this session (more than the hub sends at once).
            if text == "long history" {
                b.items[sid] = (0..<350).map { i in
                    ConversationItem(id: "\(sid)-old\(i)", kind: i % 3 == 0 ? .userText("Older step \(i): check the parser.")
                        : .assistantText("Older reply \(i). " + String(repeating: "The reader wraps this text to the column width. ", count: 2 + i % 3)))
                } + (b.items[sid] ?? [])
            }
            // "longer history": 1000 more older rows, past the PWA's auto-load cap.
            if text == "longer history" {
                b.items[sid] = (0..<1000).map { i in
                    ConversationItem(id: "\(sid)-older\(i)", kind: .assistantText("Much older reply \(i)."))
                } + (b.items[sid] ?? [])
            }
            if text == "queue me" || text == "queue stop" {
                b.screens["w2:p2"] = queueScreen()
                b.pullOutcome = text == "queue me" ? .pulled(pulledText) : .interrupted(pulledText)
                setStatus("w2:p2", .working)
            }
            // "queue slow": a pull that takes 1.5 s; "queue partial": one that stopped before the box was empty.
            if text == "queue slow" || text == "queue partial" {
                b.screens["w2:p2"] = queueScreen()
                b.pullDelay = text == "queue slow" ? .milliseconds(1500) : .zero
                b.pullOutcome = text == "queue slow" ? .pulled("Slow one.")
                    : .partial(pulledText, "The agent's input box changed while Flockbook cleared it, so it stopped. Check the agent's terminal before you send it.")
                setStatus("w2:p2", .working)
            }
            // "queue long": a pull QueuePull refuses before any key (a line wider than the agent's input box).
            if text == "queue long" {
                b.screens["w2:p2"] = ["⏺ Working on the notes",
                                      "❯ Also run the lint step before you commit, then fix every warning it reports, run the tests again and open a draft PR",
                                      "  ctrl+enter to send now", "· Baking… (12s)", rule, "❯ Press up to edit queued messages", rule].joined(separator: "\n")
                b.pullDelay = .zero
                b.pullOutcome = .refused("This queued text is too long or has spaces or blank lines that the agent's input box does not show, so Flockbook cannot check it exactly. Edit it in the agent's terminal. Nothing was sent.")
                setStatus("w2:p2", .working)
            }
            // "codex queue": the working Codex (w2:p1) has a queued message on its screen.
            if text == "codex queue" {
                b.screens["w2:p1"] = ["› Run the test suite", "• Working (30s • esc to interrupt)", "• Queued follow-up inputs",
                                      "  ↳ Check the retry count too.", "    ⇧← edit last queued message", "› Ask Codex to do anything",
                                      "  GPT-5 · Context 96% left", "  ? for shortcuts"].joined(separator: "\n")
                setStatus("w2:p1", .working)
            }
            // "keep three": texts the hub kept for this phone and never got a pulledAck for (sent again after hello).
            if text == "keep three" {
                for (pane, t) in [("w2:p2", "Kept one."), ("w1:p2", "Kept for the other agent."), ("w2:p2", "Kept two.")] {
                    _ = b.pulledTexts.keep(PulledText(pane: pane, device: "d-input", text: t))
                }
            }
            // "keep warned": a partial pull's text kept for the other agent (sent again after hello, with its reason).
            if text == "keep warned" {
                _ = b.pulledTexts.keep(PulledText(pane: "w1:p2", device: "d-input", text: "Warned one.",
                                                  note: "Some of it may still be in the agent's input box. Check the agent's terminal before you send it."))
            }
            // "slow send": the next send takes 1.5 s.
            if text == "slow send" { b.sendDelay = .milliseconds(1500) }
            if text == "queue busy" { b.screens["w2:p2"] = queueScreen(input: "❯ half typed"); setStatus("w2:p2", .working) }
            // "ask me": Claude opens a question picker (read from the screen only).
            if text == "ask me" { b.screens["w2:p2"] = claudePicker; setStatus("w2:p2", .blocked) }
            if text == "compact me" { compacting = 1; setStatus("w2:p2", .working) }
            if text == "compact done" { compacting = 0; b.screens["w2:p2"] = "> "; setStatus("w2:p2", .idle) }
        }
        if compacting > 0 {
            compacting += 1
            b.screens["w2:p2"] = "✻ Compacting conversation… (\(compacting / 10)s · ↓ \(compacting * 37) tokens · esc to interrupt)\n\n> "
        }
        seen = now
        try? await Task.sleep(for: .milliseconds(100))
        for line in stdinLines() {
            let w = line.split(separator: " ").map(String.init)
            if w.count == 3, w[0] == "pictures", b.items[w[2]] == nil {
                let file = dir.appendingPathComponent("\(w[2]).jsonl")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // Stills (web-test --shots): drawn pictures of a fictional app screen in the same shapes, and words to match.
                if let drawn = ProcessInfo.processInfo.environment["SERVE_WEB_PICTURES"] {
                    func load(_ name: String) -> Data? { try? Data(contentsOf: URL(fileURLWithPath: drawn).appendingPathComponent(name)) }
                    let user = ["card-thumb.jpg", "card-before-1600.png"].compactMap(load), tool = ["card-after-900.png"].compactMap(load)
                    let say = ["Two fixed sizes cause it: the total is 54 pt in a 150 pt frame, and seven bars of 34 pt need more than a 320 pt screen.",
                               "The bars now share the width, and the total uses a smaller size that scales with Dynamic Type.",
                               "On the iPhone SE the whole week fits, and the pickup row shows its full time."]
                    if let items = try? pictureLog(file, user: user, tool: tool, tail: 40,
                                                   text: "The harvest card is cramped on the iPhone SE. Can you fix the layout?",
                                                   say: { $0 == 39 ? "Done: the card fits on a 320 pt screen." : say[$0 % say.count] }) {
                        b.items[w[2]] = items; b.logURLs[w[2]] = file
                    }
                } else {
                    let user = [noisyImage(.jpeg, w: 120, h: 80, seed: 3), noisyImage(.png, w: 1600, h: 1200, seed: 4)].compactMap { $0 }
                    let tool = [noisyImage(.png, w: 900, h: 600, seed: 5)].compactMap { $0 }
                    if let items = try? pictureLog(file, user: user, tool: tool, tail: 40) { b.items[w[2]] = items; b.logURLs[w[2]] = file }
                }
            }
            // `session <pane> <session> [rows]`: a new agent session in that pane (40 rows of its own unless given).
            if w.count == 3 || w.count == 4, w[0] == "session" || w[0] == "pictures" {
                if b.items[w[2]] == nil {
                    b.items[w[2]] = (0..<(w.count == 4 ? Int(w[3]) ?? 40 : 40)).map { ConversationItem(id: "\(w[2])-\($0)", kind: .assistantText("New session reply \($0). " + String(repeating: "Text to wrap. ", count: 6))) }
                }
                for wi in ws.indices { for ti in ws[wi].tabs.indices { for pi in ws[wi].tabs[ti].panes.indices where ws[wi].tabs[ti].panes[pi].id == w[1] {
                    ws[wi].tabs[ti].panes[pi].agent?.sessionId = w[2]
                } } }
                b.workspaces = ws
            }
            // `nosession <pane>`: the agent there has no session now (it ended); no new conversation is sent.
            if w.count == 2, w[0] == "nosession" {
                for wi in ws.indices { for ti in ws[wi].tabs.indices { for pi in ws[wi].tabs[ti].panes.indices where ws[wi].tabs[ti].panes[pi].id == w[1] {
                    ws[wi].tabs[ti].panes[pi].agent?.sessionId = nil
                } } }
                b.workspaces = ws
            }
            // `rich <session> <rows>`: that many older rows in front, of a real reply's weight (paragraphs, lists, code).
            if w.count == 3, w[0] == "rich", let n = Int(w[2]) {
                b.items[w[1]] = (0..<n).map { i in
                    if i % 4 == 0 { return ConversationItem(id: "\(w[1])-rich\(i)", kind: .userText("Rich step \(i): check the parser and report what changed.")) }
                    var s = "Rich reply \(i)."
                    for p in 0..<(1 + (i * 7) % 6) {
                        s += "\n\nParagraph \(p): the reader shows this text wrapped to the column width, with **bold** and `code` spans, long enough to take several lines."
                        if p % 3 == 1 { s += "\n\n- first point\n- second point with more words\n- third" }
                        if p % 4 == 2 { s += "\n\n```swift\nlet value = parse(line)\nprint(value)\n```" }
                    }
                    return ConversationItem(id: "\(w[1])-rich\(i)", kind: .assistantText(s))
                } + (b.items[w[1]] ?? [])
            }
            if w.count == 3, w[0] == "grow", let n = Int(w[2]) {
                let start = b.items[w[1]]?.count ?? 0
                b.items[w[1], default: []] += (start..<(start + n)).map { i in
                    ConversationItem(id: "\(w[1])-g\(i)", kind: i % 3 == 0 ? .userText("Step \(i): check the parser.")
                        : .assistantText("Reply \(i). " + String(repeating: "The reader wraps this text to the column width, long enough to take several lines. ", count: 3 + i % 4)))
                }
            }
        }
        if stdinDone() { break }
    }
    server.stop()
    exit(0)
}

/// True once stdin is at end (the test script closed it).
nonisolated(unsafe) private var stdinEOF = false
nonisolated(unsafe) private var stdinBuffer: [UInt8] = []
private func stdinDone() -> Bool { stdinEOF }
/// Whole lines that arrived on stdin since the last call (reads what is there, never waits).
private func stdinLines() -> [String] {
    var fds = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
    while !stdinEOF, poll(&fds, 1, 0) > 0 {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(0, &chunk, chunk.count)
        if n <= 0 { stdinEOF = true } else { stdinBuffer += chunk[..<n] }
    }
    var lines: [String] = []
    while let nl = stdinBuffer.firstIndex(of: 0x0A) {
        lines.append(String(decoding: stdinBuffer[..<nl], as: UTF8.self))
        stdinBuffer.removeFirst(nl + 1)
    }
    return lines
}
