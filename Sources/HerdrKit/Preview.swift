import Foundation

extension HerdrStore {
    /// Mock tree shaped like a real snapshot. For SwiftUI previews and offline development.
    public static var preview: HerdrStore {
        let s = HerdrStore(session: .default())
        s.setPreview(workspaces: PreviewData.workspaces, connected: true)
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
