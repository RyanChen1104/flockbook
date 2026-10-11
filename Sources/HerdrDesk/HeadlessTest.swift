import HerdrKit
import Foundation
import AppKit

/// `--session <named> --test-approve <paneId> [--deny]`: exercises checkPrompt + approve without a window.
/// Refuses to run on the default session.
@MainActor
enum HeadlessTest {
    static func approve(model: AppModel, paneId: String, allow: Bool) async {
        try? await Task.sleep(for: .seconds(3))
        await model.store.refresh()
        guard let pane = model.store.workspaces.flatMap(\.tabs).flatMap(\.panes).first(where: { $0.id == paneId }) else {
            print("test: pane \(paneId) not found"); NSApp.terminate(nil); return
        }
        print("test: agent status = \(pane.agent?.status.rawValue ?? "none")")
        await model.checkPrompt(for: pane)
        print("test: promptVisible = \(model.promptVisible.contains(pane.id)) writes = \(model.writesEnabled)")
        model.approve(pane: pane, allow: allow)
        try? await Task.sleep(for: .seconds(4))
        let after = model.store.workspaces.flatMap(\.tabs).flatMap(\.panes).first(where: { $0.id == paneId })
        print("test: after status = \(after?.agent?.status.rawValue ?? "none") notice = \(model.notice ?? "-")")
        NSApp.terminate(nil)
    }

    /// `--session <named> --test-notice <paneId> [--deny]`: the notification buttons' path without the notification
    /// center (it needs a bundle): the bound prompt, then an action with a stale prompt id (must send nothing), then the
    /// real action (must send the card's input).
    static func notice(model: AppModel, paneId: String, allow: Bool) async {
        try? await Task.sleep(for: .seconds(3))
        await model.store.refresh()
        guard let tab = model.store.workspaces.flatMap(\.tabs).first(where: { $0.panes.contains { $0.id == paneId } }) else {
            print("test: pane \(paneId) not found"); NSApp.terminate(nil); return
        }
        let bound = await model.approvalPrompt(in: tab)
        print("test: buttons = \(bound.map { "pane \($0.pane) prompt \($0.prompt)" } ?? "none")")
        guard let bound else { NSApp.terminate(nil); return }
        let action = (allow ? ApprovalNotice.Action.allow : .deny).rawValue
        let stale = await model.answerNotice(action: action, paneID: bound.pane, prompt: "toolu_stale")
        try? await Task.sleep(for: .seconds(1))
        let still = await model.store.client.checkPrompt(paneId: bound.pane)
        print("test: stale prompt id -> sent = \(stale), prompt still on screen = \(still)")
        let sent = await model.answerNotice(action: action, paneID: bound.pane, prompt: bound.prompt)
        try? await Task.sleep(for: .seconds(4))
        let after = model.store.workspaces.flatMap(\.tabs).flatMap(\.panes).first(where: { $0.id == paneId })
        let gone = await !model.store.client.checkPrompt(paneId: bound.pane)
        print("test: \(allow ? "allow" : "deny") -> sent = \(sent), prompt gone = \(gone), status = \(after?.agent?.status.rawValue ?? "none") notice = \(model.notice ?? "-")")
        NSApp.terminate(nil)
    }
}
