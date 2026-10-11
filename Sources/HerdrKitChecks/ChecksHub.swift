import Foundation
@testable import HerdrKit

// Remote protocol v1 (docs/design/remote-protocol.md): every fixture round-trips, every message type has a fixture,
// the client side is intent only, versions are enforced, and the models map to the wire types.
@MainActor func checksHubProtocol() async throws {
    let dir = fixtures.appendingPathComponent("hub")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".json") }.sorted() ?? []
    check(names.count >= 18, "hub: fixtures present (\(names.count))")
    func object(_ d: Data) -> NSObject? { try? JSONSerialization.jsonObject(with: d) as? NSObject }

    // Round trip: decode, encode, same JSON. Collect the types seen.
    var clientSeen: Set<String> = [], hubSeen: Set<String> = []
    for n in names {
        let data = try Data(contentsOf: dir.appendingPathComponent(n))
        let type = (object(data) as? [String: Any])?["type"] as? String ?? ""
        let again: Data?
        if Hub.clientTypes.contains(type) {
            again = (try? Hub.decodeClient(data)).flatMap { try? Hub.encode($0) }
            clientSeen.insert(type)
        } else {
            again = (try? Hub.decodeHub(data)).flatMap { try? Hub.encode($0) }
            hubSeen.insert(type)
        }
        check(again.flatMap(object) == object(data) && object(data) != nil, "hub: \(n) round-trips")
    }
    let lossy = Data(#"{"v":1,"type":"status","pane":"w1:p1","status":"idle","extra":1}"#.utf8)
    check((try? Hub.decodeHub(lossy)).flatMap { try? Hub.encode($0) }.flatMap(object) != object(lossy), "hub: the round-trip compare sees a lost field")
    check(clientSeen == Set(Hub.clientTypes), "hub: a fixture for every client type (missing \(Set(Hub.clientTypes).subtracting(clientSeen).sorted()))")
    check(hubSeen == Set(Hub.hubTypes), "hub: a fixture for every hub type (missing \(Set(Hub.hubTypes).subtracting(hubSeen).sorted()))")

    // Intent only: no client message carries keys or bytes.
    check(Hub.clientTypes == ["hello", "watch", "unwatch", "loadEarlier", "send", "approve", "answer", "ping"], "hub: client types are the intent list")
    check(Hub.version == 1, "hub: protocol version 1")

    // Decoded values.
    let approve = try? Hub.decodeClient(fixture("hub/approve.json"))
    check(approve == ClientMessage(id: "c6", body: .approve(pane: "w1:p1", prompt: "toolu_01ABCDEF", allow: true)), "hub: approve decodes to its fields")
    let answer = try? Hub.decodeClient(fixture("hub/answer.json"))
    check(answer == ClientMessage(id: "c7", body: .answer(pane: "w1:p2", question: "screen-1a2b3c",
                                                          answers: [.init(picks: [0]), .init(picks: [], other: "Use the staging host")])), "hub: answer decodes to its fields")
    if case .prompt(let p)? = try? Hub.decodeHub(fixture("hub/prompt-none.json")) {
        check(p.approval == nil && p.question == nil && p.pane == "w1:p1", "hub: prompt with neither = no prompt open")
    } else { check(false, "hub: prompt-none decodes") }

    // Versions and unknown types.
    func thrown(_ f: () throws -> Any) -> Hub.DecodeError? { do { _ = try f(); return nil } catch { return error as? Hub.DecodeError } }
    let v2 = Data(#"{"v":2,"type":"ping","id":"c1"}"#.utf8)
    check(thrown { try Hub.decodeClient(v2) } == .unsupportedVersion(2), "hub: v2 client message refused")
    check(thrown { try Hub.decodeHub(Data(#"{"v":2,"type":"pong"}"#.utf8)) } == .unsupportedVersion(2), "hub: v2 hub message refused")
    check(thrown { try Hub.decodeClient(Data(#"{"type":"ping","id":"c1"}"#.utf8)) } == .missingVersion, "hub: message without v refused")
    check(thrown { try Hub.decodeClient(Data(#"{"v":1,"type":"keys","id":"c1","pane":"w1:p1","keys":["Enter"]}"#.utf8)) } == .unknownType("keys"),
          "hub: a raw-keys message is unknown")
    check(thrown { try Hub.decodeHub(Data(#"{"v":1,"type":"future"}"#.utf8)) } == .unknownType("future"), "hub: unknown hub type reported (the client skips it)")
    let extra = Data(#"{"v":1,"type":"watch","id":"c2","pane":"w1:p1","newField":true}"#.utf8)
    check((try? Hub.decodeClient(extra)) == ClientMessage(id: "c2", body: .watch(pane: "w1:p1")), "hub: unknown fields are ignored")

    // Models -> wire.
    let ws = try SnapshotParser.parse(fixture("snapshot.json"))
    let wire = ws.map(HubWorkspace.init)
    check(wire.count == ws.count && wire.first?.tabs.count == ws.first?.tabs.count, "hub: workspaces map")
    if let p = ws.flatMap(\.tabs).flatMap(\.panes).first(where: { $0.agent != nil }), let wp = wire.flatMap(\.tabs).flatMap(\.panes).first(where: { $0.id == p.id }) {
        check(wp.agent?.status == p.agent?.status && wp.agent?.session == p.agent?.sessionId && wp.cwd == p.cwd, "hub: pane and agent map")
        let json = String(decoding: try Hub.encode(wp), as: UTF8.self)
        check(!json.contains(p.terminalId) || p.terminalId.isEmpty, "hub: terminal ids stay in the hub")
    } else { check(false, "hub: snapshot fixture has an agent pane") }

    let t = Date(timeIntervalSince1970: 1_791_792_004.25)   // 2026-10-12T08:00:04.250Z
    check(HubItem(ConversationItem(id: "a", kind: .assistantText("Hi"), timestamp: t)) == HubItem(id: "a", kind: .assistant, time: "2026-10-12T08:00:04.250Z", text: "Hi"),
          "hub: assistant item with a millisecond time")
    check(HubItem(ConversationItem(id: "u", kind: .userText("Go"))) == HubItem(id: "u", kind: .user, text: "Go"), "hub: user item without time")
    check(HubItem(ConversationItem(id: "s", kind: .status("Interrupted"))).kind == .status, "hub: status item")
    let call = ToolCall(id: "toolu_1", toolName: "Bash", summary: "ls", input: "{\"command\":\"ls\"}", output: "secret output", isError: false)
    let chips = HubItem(ConversationItem(id: "t", kind: .toolChips([ToolChip(symbol: "terminal", text: "Ran 1 command", calls: [call])])))
    check(chips.tools?.first?.calls.first == HubToolCall(id: "toolu_1", tool: "Bash", summary: "ls", done: true, error: false), "hub: tool calls map without input or output")
    check(!String(decoding: try Hub.encode(chips), as: UTF8.self).contains("secret output"), "hub: tool output is not sent")
    let running = ToolCall(id: "toolu_2", toolName: "Bash", summary: "sleep", input: "", output: nil, isError: false)
    check(HubItem(ConversationItem(id: "t2", kind: .toolChips([ToolChip(symbol: "terminal", text: "Running", calls: [running])]))).tools?.first?.calls.first?.done == false,
          "hub: a call without a result is not done")
    let q = QuestionRequest(toolUseId: "toolu_q", questions: [.init(header: "Target", text: "Which target?",
                            options: [.init(label: "Staging", recommended: true), .init(label: "Production", detail: "Live users")])], state: .answered(["Staging"]), headers: ["Target"])
    let hq = HubQuestion(q)
    check(hq.id == "toolu_q" && hq.state == .answered && hq.answers == ["Staging"] && hq.delivery == .picker
          && hq.questions.first?.options == [HubOption(label: "Staging", recommended: true), HubOption(label: "Production", detail: "Live users")],
          "hub: question maps (empty detail and false recommended left out)")
    check(HubQuestion(QuestionRequest(toolUseId: "x", questions: [], state: .declined)).state == .declined, "hub: declined question")

    // The open approval uses the ApprovalNotice id: the log's call, else the screen box.
    let screen = """
    ────────────────────────────────────────
     Bash command
     Build the web app
    ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
     npm run build
    ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
     Do you want to proceed?
     ❯ 1. Yes
       2. No

     Esc to cancel · Tab to amend
    """
    let noLog = ApprovalNotice.PaneState(agentKind: "claude", blocked: true, pendingToolUseId: nil, screen: screen)
    let a1 = Hub.openApproval(noLog, logged: nil)
    check(a1 != nil && a1?.id == ApprovalNotice.prompt(noLog, writes: true) && a1?.command == "npm run build" && a1?.tool == "Bash", "hub: screen-only approval has the notification's id")
    var withLog = noLog; withLog.pendingToolUseId = "toolu_9"
    let logged = PermissionRequest(title: "Wants to run a command", command: "npm run build", toolName: "Bash", toolUseId: "toolu_9")
    let a2 = Hub.openApproval(withLog, logged: logged)
    check(a2?.id == "toolu_9" && a2?.id == ApprovalNotice.prompt(withLog, writes: true) && a2?.title == "Wants to run a command", "hub: logged approval has the notification's id")
    check(Hub.openApproval(noLog, logged: nil) == Hub.openApproval(noLog, logged: nil), "hub: approval id is stable")
    var picker = noLog; picker.screen = "←  ☐ Deploy  ✔ Submit  →\nDo you want to deploy?\n❯ 1. Yes\n  2. No\n────\n  Chat about this"
    check(Hub.openApproval(picker, logged: nil) == nil, "hub: a question picker is not an approval")
    var idle = noLog; idle.blocked = false
    check(Hub.openApproval(idle, logged: nil) == nil, "hub: no approval when the agent is not blocked")
}
