import AppKit
import HerdrKit
import SwiftUI

/// Live check of the question card against a real agent pane (`--session <name> --test-question-live <paneId>`, picks in env
/// PICKS, 0-based, e.g. `[[1],[0]]`). Named sessions only: the default session is refused. Offscreen window, under 60 s.
/// From inside a herdr pane, strip herdr's env first (PLAN.md), or the herdr CLI may follow this pane's socket:
///   PICKS='[[1],[0]]' env -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_ENV \
///     timeout -k 5 60 .build/debug/HerdrDesk --session <test-session> --test-question-live <paneId>
/// The card is driven by key events through PaneView's real handlers (pendingQuestion / log item, loadAllQuestions,
/// answerQuestion); HerdrClient is called directly only to read the screen for the "appear sends no keys" check.
extension ContentTests {
    static func questionLive(_ args: [String]) async {
        var failures = 0
        func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("question-live: \(n) \(ok ? "ok" : "FAIL")") }
        func done() -> Never {
            print("question-live: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
            exit(failures == 0 ? 0 : 1)
        }
        let session = HerdrSession.fromLaunch(arguments: args, environment: ProcessInfo.processInfo.environment)
        guard let i = args.firstIndex(of: "--test-question-live"), args.indices.contains(i + 1), !args[i + 1].hasPrefix("--"),
              session.name != nil else {
            print("question-live: usage: PICKS='[[1],[0]]' env -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_ENV HerdrDesk --session <name> --test-question-live <paneId> (named session only; the default session is refused)")
            exit(2)
        }
        let paneId = args[i + 1]
        guard let data = ProcessInfo.processInfo.environment["PICKS"]?.data(using: .utf8),
              let picks = try? JSONDecoder().decode([[Int]].self, from: data), !picks.isEmpty else {
            print("question-live: set PICKS to a JSON list of 0-based picks per question, e.g. PICKS='[[1],[0]]'"); exit(2)
        }
        let started = Date()
        let store = HerdrStore(session: session)
        let model = AppModel(store: store)
        step("writes on (no --read-only)", model.writesEnabled)
        store.start()

        // (1) The agent turns blocked (read from herdr only; no card yet).
        func pane() -> Pane? { store.workspaces.flatMap(\.tabs).flatMap(\.panes).first { $0.id == paneId } }
        while pane()?.agent?.status != .blocked, Date().timeIntervalSince(started) < 40 {
            await store.refresh()
            try? await Task.sleep(for: .seconds(1))
        }
        guard let agent = pane()?.agent, agent.status == .blocked else { step("pane \(paneId) agent blocked within 40 s", false); done() }
        step("pane \(paneId) agent \(agent.name) (\(agent.kind)) blocked", true)

        // (2) Screen before the card exists, then the card appears; the screen must not change.
        let before = try? await store.client.visibleText(paneId: paneId)
        var events: [QuestionProbe.Event] = []
        var request: QuestionRequest?, flow: QuestionFlow?, loaded = 0, sent = false, failed: String?
        QuestionProbe.report = { e in
            events.append(e)
            switch e {
            case .appeared(let q): request = q
            case .flow(let f): flow = f
            case .loaded: loaded += 1
            case .sent: sent = true
            case .failed(let why): failed = why
            }
        }
        let size = NSSize(width: 1200, height: 800)
        let host = NSHostingView(rootView: LiveQuestionPane(paneId: paneId).environment(model).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = host; win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()
        while request == nil, Date().timeIntervalSince(started) < 45 { try? await Task.sleep(for: .milliseconds(200)) }
        guard let q = request else { step("card appears (PaneView: \(agent.kind == "claude" ? "pendingQuestion" : "log item"))", false); done() }
        step("card appears: \(q.toolUseId), \(q.questions.count) read, \(q.headers.count) headers, unread \(q.unread), delivery \(q.delivery)", true)
        try? await Task.sleep(for: .seconds(1))
        let after = try? await store.client.visibleText(paneId: paneId)
        step("appear sends no keys (screen unchanged)", before != nil && before == after)
        let total = max(q.questions.count, q.headers.count)
        step("PICKS has one entry per question (\(picks.count) for \(total))", picks.count == total)
        guard picks.count == total else { done() }

        // (3) Pick, Return (Next; reads the rest on Claude with unread > 0), then Send, all as key events on the card.
        func press(_ ch: String, _ code: UInt16) async {
            for t in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: win.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                            isARepeat: false, keyCode: code) { win.sendEvent(e) }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let digitCodes: [UInt16] = [0, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (k, ps) in picks.enumerated() {
            guard flow?.step == k else { step("on question \(k + 1) (card at \((flow?.step ?? -1) + 1))", false); done() }
            for p in ps where (0..<9).contains(p) { await press("\(p + 1)", digitCodes[p + 1]) }
            step("question \(k + 1): picks \(flow?.picks[k].sorted() ?? []) (wanted \(ps.sorted()))", flow?.picks[k] == Set(ps))
            let loadsBefore = loaded
            await press("\r", 36)
            let last = k == picks.count - 1
            let deadline = Date().addingTimeInterval(last ? 25 : 12)
            while Date() < deadline, failed == nil, last ? !sent : flow?.step != k + 1 { try? await Task.sleep(for: .milliseconds(200)) }
            if let failed { step("question \(k + 1): \(failed)", false); done() }
            if last {
                step("send ok (no error from onSend)", sent)
            } else {
                step("Next goes to question \(k + 2)", flow?.step == k + 1)
                if k == 0, q.unread > 0 { step("Next on question 1 read the rest once (loadAllQuestions: \(loaded - loadsBefore))", loaded - loadsBefore == 1) }
            }
        }
        QuestionProbe.report = nil
        print("question-live: \(Int(Date().timeIntervalSince(started))) s")
        done()
    }
}

/// The pane as the app shows it, kept current from the store (status and log change while the test runs).
private struct LiveQuestionPane: View {
    @Environment(AppModel.self) private var model
    let paneId: String
    var body: some View {
        if let p = model.store.workspaces.flatMap(\.tabs).flatMap(\.panes).first(where: { $0.id == paneId }) {
            PaneView(pane: p, showLabel: false, focused: true)
        } else {
            Text("No pane \(paneId)")
        }
    }
}
