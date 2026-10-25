import HerdrKit
import Foundation
import AppKit

/// `--remote <host> --session <named> --test-remote-live <paneId>`: a real Claude Code on a test host, through the app's
/// own paths: a message from the composer's send, an attached picture, the question hook (install, a question, an answer) and the status
/// line (on, a line read back, off). The hook is put back as it was; the status line always ends off. Refuses this Mac
/// and the default session.
@MainActor
enum RemoteLiveTest {
    static func run(model: AppModel, paneId: String) async {
        var failures = 0
        func step(_ what: String, _ ok: Bool) { if !ok { failures += 1 }; print("remote-live: \(what) \(ok ? "ok" : "FAIL")") }
        func done() { print("remote-live: \(failures == 0 ? "PASS" : "FAIL x\(failures)")"); NSApp.terminate(nil) }
        let store = model.store
        guard store.session.remote != nil, store.session.name != nil else { print("remote-live: needs --remote and a named --session"); done(); return }
        func wait(_ seconds: Double, _ ok: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if ok() { return true }; try? await Task.sleep(for: .milliseconds(500)) }
            return ok()
        }
        func waitAsync(_ seconds: Double, _ ok: () async -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if await ok() { return true }; try? await Task.sleep(for: .milliseconds(500)) }
            return await ok()
        }
        func agent() -> Agent? { store.workspaces.flatMap(\.tabs).flatMap(\.panes).first { $0.id == paneId }?.agent }
        guard await wait(20, { agent()?.sessionId != nil }), let first = agent(), let sid = first.sessionId else {
            print("remote-live: pane \(paneId) has no Claude session"); done(); return
        }
        func said(_ token: String) -> Bool {
            store.conversation(for: sid).contains { if case .assistantText(let t) = $0.kind { t.contains(token) } else { false } }
        }
        func idle() async -> Bool { await wait(90, { agent()?.status == .idle || agent()?.status == .done }) }

        // 1. A message from the app: Claude Code answers it, and the answer is read back from the host's log.
        let token = "app-sent-\(Int.random(in: 1000...9999))"
        let sent = await model.deliver("Reply with exactly: \(token)", pane: paneId, kind: first.kind)
        step("send: submitted", sent)
        step("send: the answer comes back from the host's log", await wait(90, { said(token) }))

        // 1b. An attached picture (a chip, as the composer's attach or drop makes it): the send copies it to the host and
        // pastes the host path, and Claude Code on the host reads it.
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("remote-live-\(token).png")
        let red = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill(); r.fill(); return true }
        try? red.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }?.write(to: png)
        let chips = PasteImages.take([png]).images
        try? FileManager.default.removeItem(at: png)
        step("picture: a chip from the attached file", chips.count == 1)
        if let chip = chips.first {
            _ = await idle()
            let message = "What single colour fills this picture? Reply with exactly: colour-<the colour in lower case>-\(token) \(ComposerHandle.quoted(chip))"
            let started = Date()
            let ok = await model.deliver(message, pane: paneId, kind: first.kind)
            step("picture: submitted (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)", ok)
            if !ok {
                print("remote-live: why \(MessageSender.takeFailure(message) ?? "-")")
                let screen = (try? await store.client.visibleText(paneId: paneId)) ?? "(unreadable)"
                print("remote-live: screen tail \(screen.split(separator: "\n").suffix(8).map(String.init))")
            }
            step("picture: Claude Code on the host saw a red picture", await wait(120, { said("colour-red-\(token)") }))
            PasteImages.remove(chip)
        }

        // 2. The question hook on the host: install, a question shows, an answer reaches Claude Code.
        let hook = ClaudeHookSetup.live
        hook.refresh()
        _ = await wait(15, { !hook.busy })
        let hookWasOn = hook.state == .on
        if !hookWasOn { hook.install() }
        step("hook: on for the host (\(hook.machine))", await wait(20, { !hook.busy && hook.state == .on }))
        _ = await idle()
        _ = await model.deliver("Use the AskUserQuestion tool to ask me one question: \"Pick a fruit\" with the options Apple and Pear. After my answer, reply with exactly: picked-<the fruit in lower case>-\(token).",
                            pane: paneId, kind: first.kind)
        var question: QuestionRequest?
        step("hook: the question is read from the host", await wait(90, { question = hook.question(session: sid); return question != nil }))
        if let q = question {
            print("remote-live: question \(q.questions.first?.text ?? "?") options \(q.questions.first?.options.map(\.label) ?? [])")
            // The hook fires before Claude Code draws the picker: answer once the picker is on screen, as a click would.
            var screen = ""
            step("hook: the picker is on screen", (await waitAsync(30) { screen = (try? await store.client.visibleText(paneId: paneId)) ?? ""; return QuestionAdapter.screenShows(q, screen: screen) }))
            do {
                try await store.client.answerQuestion(paneId: paneId, request: q, answers: [QuestionAnswer(picks: [0])])
                step("hook: answer sent", true)
            } catch { step("hook: answer sent (\(String(reflecting: error)))", false) }
            step("hook: Claude Code got the first option", await wait(90, { said("picked-apple-\(token)") }))
            let tail = store.conversation(for: sid).suffix(4).map { "\($0.kind)".prefix(80) }
            print("remote-live: last items \(tail) state \(store.conversationState(for: sid)) connected \(store.connected)")
        }
        if !hookWasOn { hook.uninstall(); _ = await wait(20, { !hook.busy }); step("hook: off again", hook.state == .off) }

        // 3. The status line on the host: on, a line is saved for this session and read back, off again.
        let status = StatusLineSetup.live
        status.refresh()
        _ = await wait(15, { !status.busy })
        let statusWasOn = status.state == .on
        if !statusWasOn { status.turnOn() }
        step("status line: on for the host (\(status.machine))", await wait(20, { !status.busy && status.state == .on }))
        _ = await idle()
        _ = await model.deliver("Reply with exactly: status-\(token)", pane: paneId, kind: first.kind)
        var line: StatusLineRecord?
        step("status line: a line is read from the host", await wait(90, { line = status.record(session: sid); return line != nil }))
        if let line { print("remote-live: status info \(line.info.map { "\($0.model ?? "-") ctx \($0.contextPercent.map(String.init) ?? "-")%" } ?? "none")") }
        if let line { print("remote-live: status line \(line.lines.map { $0.map(\.text).joined() }.joined(separator: " | ").prefix(120).debugDescription)") }
        // Off at the end whatever it was before, so the off path runs every time (a test host only).
        status.turnOff()
        _ = await wait(2, { status.busy })
        step("status line: off (was \(statusWasOn ? "on" : "off") before)", await wait(30, { !status.busy && status.state == .off }))
        if status.state != .off { print("remote-live: status line state \(status.state)") }
        done()
    }
}
