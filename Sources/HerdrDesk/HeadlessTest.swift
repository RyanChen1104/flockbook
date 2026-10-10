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
}
