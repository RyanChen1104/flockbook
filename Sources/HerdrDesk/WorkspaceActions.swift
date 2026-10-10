import AppKit
import HerdrKit
import SwiftUI

/// One entry of a right-click menu. The menu views and the offscreen tests both read this list, so what the test sees is what the owner gets.
struct MenuEntry: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var enabled = true
    var destructive = false
    let run: () -> Void
}

struct MenuEntries: View {
    let entries: [MenuEntry]
    var body: some View {
        ForEach(entries) { e in
            Button(role: e.destructive ? .destructive : nil, action: e.run) { Label(e.title, systemImage: e.symbol) }
                .disabled(!e.enabled)
        }
    }
}

extension AppModel {
    func tabMenu(_ t: Tab) -> [MenuEntry] {
        let w = writesEnabled
        return [
            MenuEntry(id: "rename", title: "Rename…", symbol: "pencil", enabled: w) { [self] in renamingTabID = t.id },
            MenuEntry(id: "moveLeft", title: "Move left", symbol: "arrow.left", enabled: w && tabIndex(t).map { $0 > 0 } == true) { [self] in moveTab(t, by: -1) },
            MenuEntry(id: "moveRight", title: "Move right", symbol: "arrow.right",
                      enabled: w && tabIndex(t).map { $0 < (workspace?.tabs.count ?? 0) - 1 } == true) { [self] in moveTab(t, by: 1) },
            MenuEntry(id: "close", title: "Close tab", symbol: "xmark", enabled: w, destructive: true) { [self] in closeTab(t) },
            MenuEntry(id: "splitRight", title: "Split right", symbol: "rectangle.split.2x1", enabled: w) { [self] in split(tab: t, .right) },
            MenuEntry(id: "splitDown", title: "Split down", symbol: "rectangle.split.1x2", enabled: w) { [self] in split(tab: t, .down) },
            MenuEntry(id: "overview", title: "Show in Overview", symbol: "square.grid.2x2") { [self] in screen = .overview },
        ]
    }

    /// Keyboard and menu path of drag reordering: one place left (-1) or right (+1) in the current workspace.
    func moveTab(_ t: Tab, by d: Int) {
        guard let i = tabIndex(t), let n = workspace?.tabs.count, (0..<n).contains(i + d) else { return }
        moveTab(t, to: i + d)
    }
    private func tabIndex(_ t: Tab) -> Int? { workspace?.tabs.firstIndex { $0.id == t.id } }

    func workspaceMenu(_ ws: Workspace) -> [MenuEntry] {
        let w = writesEnabled
        return [
            MenuEntry(id: "rename", title: "Rename…", symbol: "pencil", enabled: w) { [self] in renamingWorkspaceID = ws.id },
            MenuEntry(id: "newTab", title: "New tab in workspace", symbol: "square.and.pencil", enabled: w) { [self] in newTab(in: ws) },
            MenuEntry(id: "close", title: "Close workspace…", symbol: "trash", enabled: w, destructive: true) { [self] in if writesEnabled { closingWorkspace = ws } },
        ]
    }

    func split(tab t: Tab, _ dir: SplitDirection) {
        guard writesEnabled, let fid = focusedPaneID(in: t) else { return }
        splitDirection = dir.rawValue
        if let hook = workspaceHook { hook("split", "\(t.id) \(dir.rawValue)"); return }
        Task { try? await store.client.split(paneId: fid, direction: dir); await store.refresh() }
    }

    /// Moves the tab to `index` (final 0-based position) in its workspace.
    func moveTab(_ t: Tab, to index: Int) {
        guard writesEnabled else { return }
        if let hook = workspaceHook { hook("moveTab", "\(t.id) \(index)"); return }
        Task { try? await store.client.moveTab(t.id, toIndex: index); await store.refresh() }
    }

    func beginNewWorkspace() { if writesEnabled { newWorkspaceOpen = true } }

    /// Creates the workspace (one tab, one shell pane), then selects it here.
    func createWorkspace(name: String, cwd: String) {
        guard writesEnabled else { return }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hook = workspaceHook { hook("create", label); return }
        Task {
            guard let id = try? await store.client.createWorkspace(label: label.isEmpty ? nil : label, cwd: cwd.isEmpty ? nil : cwd, focus: false) else { return }
            await store.refresh()
            select(workspace: id)
        }
    }

    func rename(_ ws: Workspace, to label: String) {
        renamingWorkspaceID = nil
        let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard writesEnabled, !t.isEmpty, t != ws.label else { return }
        if let hook = workspaceHook { hook("rename", "\(ws.id) \(t)"); return }
        Task { try? await store.client.renameWorkspace(id: ws.id, to: t); await store.refresh() }
    }

    func newTab(in ws: Workspace) {
        guard writesEnabled else { return }
        if let hook = workspaceHook { hook("newTab", ws.id); return }
        let cwd = ws.tabs.first?.panes.first?.cwd
        select(workspace: ws.id)
        Task { try? await store.client.createTab(workspaceId: ws.id, label: nil, cwd: cwd); await store.refresh() }
    }

    func close(_ ws: Workspace) {
        closingWorkspace = nil
        guard writesEnabled else { return }
        if let hook = workspaceHook { hook("close", ws.id); return }
        if workspaceID == ws.id, let other = store.workspaces.first(where: { $0.id != ws.id }) { select(workspace: other.id) }
        Task { try? await store.client.closeWorkspace(id: ws.id); await store.refresh() }
    }
}

/// "New workspace" sheet: a name (optional, herdr names it otherwise) and a start folder (home by default).
struct NewWorkspaceSheet: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var folder = NSHomeDirectory()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New workspace").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).focused($focused).onSubmit(create)
            HStack {
                Text(Self.pretty(folder)).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Choose…") { choose() }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.newWorkspaceOpen = false }.keyboardShortcut(.cancelAction)
                Button("Create", action: create).keyboardShortcut(.defaultAction).disabled(!model.writesEnabled)
            }
        }
        .padding(20).frame(width: 380)
        .onAppear { focused = true }
    }

    private func create() {
        model.newWorkspaceOpen = false
        model.createWorkspace(name: name, cwd: folder)
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.directoryURL = URL(fileURLWithPath: folder)
        if p.runModal() == .OK, let u = p.url { folder = u.path }
    }

    static func pretty(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
    }
}
