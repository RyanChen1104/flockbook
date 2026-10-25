import Foundation

extension HerdrStore {
    /// Mock tree shaped like a real snapshot. For SwiftUI previews and offline development.
    public static var preview: HerdrStore {
        let s = HerdrStore(session: .default())
        s.setPreview(workspaces: PreviewData.workspaces, connected: true)
        return s
    }

    /// One workspace with no tab: nothing to split (checks of the toolbar's + set to a split).
    public static var previewEmptyWorkspace: HerdrStore {
        let s = HerdrStore(session: .default())
        s.setPreview(workspaces: [Workspace(id: "w-empty", label: "empty", tabs: [])], connected: true)
        return s
    }

    /// The mock tree with a session id on every agent (`s-<agent name>`): for checks of which logs count as on screen.
    public static var previewWithSessions: HerdrStore {
        let s = HerdrStore(session: .default())
        s.setPreview(workspaces: PreviewData.workspaces.map { ws in
            Workspace(id: ws.id, label: ws.label, tabs: ws.tabs.map { t in
                Tab(id: t.id, label: t.label, number: t.number, panes: t.panes.map { p in
                    var p = p
                    if var a = p.agent { a.sessionId = "s-\(a.name)"; p.agent = a }
                    return p
                }, status: t.status)
            })
        }, connected: true)
        return s
    }

    /// Workspaces with many tabs and long names: for sidebar layout checks.
    public static var previewDense: HerdrStore {
        let sts: [AgentStatus] = [.idle, .done, .working, .blocked, .done, .idle, .done, .working, .idle, .done, .idle, .done, .idle, .done]
        func w(_ id: String, _ name: String, _ n: Int) -> Workspace {
            Workspace(id: id, label: name, tabs: (0..<n).map { PreviewData.tab("\(id)\($0)", "Tab \($0)", $0 + 1, sts[$0 % sts.count], [PreviewData.pane("\(id)\($0)", PreviewData.agent("a-\(id)\($0)-dev", sts[$0 % sts.count]))]) })
        }
        let s = HerdrStore(session: .default())
        s.setPreview(workspaces: [w("a", "Studio · Snapshot loop", 4), w("b", "Orchard · All", 12), w("c", "Meadow · Migration", 1),
                                  w("d", "Lighthouse · Refactor", 7), w("e", "Atlas", 3), w("f", "Harbor · Migration", 3)], connected: true)
        return s
    }

    /// One workspace with `count` tabs named like real agents (lengths vary): for tab row overflow checks.
    public static func previewManyTabs(_ count: Int) -> HerdrStore {
        let names = ["orchard-main-orch", "docs-dev", "lighthouse-review-dev", "atlas-data-dev", "harbor-ops-sync", "meadow-notes",
                     "orchard-web-dev", "api-dev", "studio-render-dev", "cli-dev", "harbor-deploy-dev", "web-rev"]
        let sts: [AgentStatus] = [.working, .done, .done, .idle, .done, .idle, .working, .idle, .idle, .done, .blocked]
        let tabs = (0..<count).map { i in
            let name = names[i % names.count] + (i < names.count ? "" : "-\(i / names.count + 1)")
            return PreviewData.tab("m\(i)", name, i + 1, sts[i % sts.count], [PreviewData.pane("m\(i)", PreviewData.agent(name, sts[i % sts.count]))])
        }
        let s = HerdrStore(session: .default())
        s.setPreview(workspaces: [Workspace(id: "m", label: "Orchard · Many tabs", tabs: tabs), PreviewData.workspaces[2]], connected: true)
        return s
    }

    /// Same tree with no blocked agent: the "All clear" state.
    public static var previewQuiet: HerdrStore {
        let s = HerdrStore(session: .default())
        let ws = PreviewData.workspaces.map { w in
            var w = w
            w.tabs = w.tabs.map { t in var t = t; if t.status == .blocked { t.status = .done }; return t }
            return w
        }
        s.setPreview(workspaces: ws, connected: true)
        return s
    }
}

enum PreviewData {
    static func agent(_ n: String, _ st: AgentStatus) -> Agent {
        Agent(name: n, kind: "claude", status: st, sessionId: nil, title: n)
    }
    static func pane(_ id: String, _ a: Agent?) -> Pane {
        Pane(id: "p\(id)", terminalId: "term_\(id)", cwd: "~/Orchard", agent: a)
    }
    static func tab(_ id: String, _ label: String, _ n: Int, _ st: AgentStatus, _ panes: [Pane]) -> Tab {
        Tab(id: id, label: label, number: n, panes: panes, status: st)
    }

    static var workspaces: [Workspace] { [
        Workspace(id: "w1", label: "Orchard", tabs: [
            tab("a", "Orchestrator", 1, .idle, [pane("1", agent("orchard-main-orch", .idle)), pane("2", nil)]),
            tab("b", "Mobile view", 2, .blocked, [pane("3", agent("orchard-web-dev", .blocked))]),
            tab("c", "Core runtime", 3, .working, [pane("4", agent("orchard-api-dev", .working))]),
            tab("d", "Architecture review", 4, .done, [pane("5", agent("orchard-arch-rev", .done))]),
        ]),
        Workspace(id: "w2", label: "Lighthouse", tabs: [
            tab("j1", "Docs", 1, .done, [pane("10", agent("lighthouse-docs-dev", .done))]),
            tab("j2", "Data import", 2, .working, [pane("11", agent("atlas-data-dev", .working))]),
        ]),
        Workspace(id: "w3", label: "Harbor", tabs: [
            tab("h1", "Main", 1, .working, [pane("12", agent("harbor-ops-dev", .working))]),
        ]),
    ] }

    /// Tab id → seconds since its agents last wrote their logs. Harbor's tab has none: no log found.
    static let logAges: [String: TimeInterval] = ["a": 180, "b": 24 * 60, "c": 10, "d": 2 * 3600, "j1": 86400 + 60, "j2": 5 * 60]

    static let conversation: [ConversationItem] = [
        ConversationItem(id: "c1", kind: .userText("Where is the team at?")),
        ConversationItem(id: "c2", kind: .assistantText("Four agents are active. One needs you: orchard-web-dev wants to run a build.")),
        ConversationItem(id: "c3", kind: .toolChips([
            ToolChip(symbol: "waveform.path.ecg", text: "Checked 8 agents"),
            ToolChip(symbol: "doc.text", text: "Read 3 files", calls: (1...3).map {
                ToolCall(id: "pv\($0)", toolName: "Read", summary: "/src/File\($0).swift", input: "{\n  \"file_path\" : \"/src/File\($0).swift\"\n}", output: "import Foundation\nstruct File\($0) {}", isError: false)
            }),
        ])),
        ConversationItem(id: "c4", kind: .permissionRequest(
            PermissionRequest(title: "orchard-web-dev wants to run a build", command: "xcodebuild -scheme Mobile build"))),
    ]
}
