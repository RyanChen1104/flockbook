import Foundation
@testable import HerdrKit

/// `--serve-web`: a hub with the bundled PWA and a fake backend, for the headless browser test (scripts/web-test.mjs).
/// TLS with a throwaway self-signed certificate, 127.0.0.1 only, never herdr. Prints one JSON line
/// (port, cert path, tokens), then serves until stdin closes. Input changes the fake state the way an agent would.
@MainActor func modeServeWeb() async throws {
    guard CommandLine.arguments.contains("--serve-web") else { return }
    let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "hkweb-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    func agent(_ s: AgentStatus, _ id: String, _ title: String, kind: String = "claude") -> Agent { Agent(name: kind, kind: kind, status: s, sessionId: id, title: title) }
    func pane(_ id: String, _ a: Agent?) -> Pane { Pane(id: id, terminalId: "term_" + id, cwd: "/work/site", agent: a) }
    var ws = [
        Workspace(id: "w1", label: "site", tabs: [
            Tab(id: "w1:t1", label: "build", number: 1, panes: [pane("w1:p1", agent(.blocked, "s1", "Fix the build"))], status: .blocked),
            Tab(id: "w1:t2", label: "deploy", number: 2, panes: [pane("w1:p2", agent(.blocked, "s2", "Deploy target"))], status: .blocked),
        ]),
        Workspace(id: "w2", label: "api", tabs: [
            Tab(id: "w2:t1", label: "tests", number: 1, panes: [pane("w2:p1", agent(.working, "s3", "Add tests", kind: "codex"))], status: .working),
            Tab(id: "w2:t2", label: "notes", number: 2, panes: [pane("w2:p2", agent(.idle, "s4", "Notes")), pane("w2:p3", nil)], status: .idle),
        ]),
    ]
    let b = FakeHubBackend(workspaces: ws)
    b.sessionName = nil
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
    let q = QuestionRequest(toolUseId: "tq1", questions: [.init(header: "Target", text: "Which target?",
                            options: [.init(label: "Staging", detail: "The test site", recommended: true), .init(label: "Production")])])
    b.items["s2"] = [ConversationItem(id: "b1", kind: .userText("Deploy it.")), ConversationItem(id: "b2", kind: .question(q))]
    b.screens["w1:p2"] = """
     ←  ☐ Target  ✔ Submit  →

    Which target?

    ❯ 1. Staging (Recommended)
         The test site
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
    var seen = (0, 0, 0)
    func setStatus(_ pane: String, _ s: AgentStatus) {
        for wi in ws.indices { for ti in ws[wi].tabs.indices { for pi in ws[wi].tabs[ti].panes.indices where ws[wi].tabs[ti].panes[pi].id == pane {
            ws[wi].tabs[ti].panes[pi].agent?.status = s; ws[wi].tabs[ti].status = s
        } } }
        b.workspaces = ws
    }
    while true {
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
            let pane = String(last.split(separator: " ")[0]), text = String(last.drop(while: { $0 != " " }).dropFirst())
            let sid = ws.flatMap(\.tabs).flatMap(\.panes).first { $0.id == pane }?.agent?.sessionId ?? ""
            b.items[sid, default: []].append(ConversationItem(id: "u\(now.2)", kind: .userText(text)))
        }
        seen = now
        try? await Task.sleep(for: .milliseconds(100))
        if stdinDone() { break }
    }
    server.stop()
    exit(0)
}

/// True once stdin is at end (the test script closed it).
nonisolated(unsafe) private var stdinEOF = false
private func stdinDone() -> Bool {
    if stdinEOF { return true }
    var fds = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
    guard poll(&fds, 1, 0) > 0 else { return false }
    var byte: UInt8 = 0
    if read(0, &byte, 1) <= 0 { stdinEOF = true }
    return stdinEOF
}
