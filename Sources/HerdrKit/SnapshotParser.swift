import Foundation

/// Turns the `session.snapshot` payload into the public model. Tolerant: unknown fields are ignored.
enum SnapshotParser {
    private struct Root: Decodable { var result: Result? ; var snapshot: Snap? }
    private struct Result: Decodable { var snapshot: Snap? }
    private struct Snap: Decodable {
        var workspaces: [WS] = []
        var tabs: [TabInfo] = []
        var panes: [PaneInfo] = []
        var agents: [AgentInfo] = []
    }
    private struct WS: Decodable { var workspace_id: String; var label: String?; var number: Int? }
    private struct TabInfo: Decodable { var tab_id: String; var workspace_id: String; var label: String?; var number: Int?; var agent_status: String? }
    private struct SessionRef: Decodable { var value: String?; var kind: String? }
    private struct PaneInfo: Decodable {
        var pane_id: String; var tab_id: String; var workspace_id: String
        var terminal_id: String?; var cwd: String?; var agent_status: String?; var label: String?
        var agent_session: SessionRef?; var terminal_title_stripped: String?; var terminal_title: String?
    }
    private struct AgentInfo: Decodable {
        var pane_id: String; var agent: String?; var name: String?; var agent_status: String?
        var agent_session: SessionRef?; var terminal_title_stripped: String?
    }

    static func parse(_ data: Data) throws -> [Workspace] {
        let root = try JSONDecoder().decode(Root.self, from: data)
        guard let snap = root.result?.snapshot ?? root.snapshot else {
            throw HerdrError.protocolError("no snapshot in response")
        }
        let agentByPane = Dictionary(snap.agents.map { ($0.pane_id, $0) }, uniquingKeysWith: { a, _ in a })

        func status(_ s: String?) -> AgentStatus { s.flatMap(AgentStatus.init(rawValue:)) ?? .unknown }

        var panesByTab: [String: [Pane]] = [:]
        for p in snap.panes {
            var agent: Agent?
            if let a = agentByPane[p.pane_id], let kind = a.agent {
                let title = a.terminal_title_stripped ?? p.terminal_title_stripped ?? a.name ?? kind
                let sid = (a.agent_session ?? p.agent_session)?.value   // id (Claude) or path (Codex)
                agent = Agent(name: a.name ?? kind, kind: kind, status: status(a.agent_status), sessionId: sid, title: title)
            }
            panesByTab[p.tab_id, default: []].append(
                Pane(id: p.pane_id, terminalId: p.terminal_id ?? "", cwd: p.cwd ?? "", agent: agent,
                     label: p.label.flatMap { $0.isEmpty ? nil : $0 }))
        }

        var tabsByWS: [String: [Tab]] = [:]
        for t in snap.tabs {
            let panes = panesByTab[t.tab_id] ?? []
            let rollup = AgentStatus.rollup(panes.compactMap { $0.agent?.status })
            let st = panes.contains { $0.agent != nil } ? rollup : status(t.agent_status)
            tabsByWS[t.workspace_id, default: []].append(
                Tab(id: t.tab_id, label: t.label ?? "", number: t.number ?? 0, panes: panes, status: st))
        }

        return snap.workspaces.map { w in
            let tabs = tabsByWS[w.workspace_id] ?? []   // snapshot order is the real tab order; `number` stays with the tab after tab.move
            return Workspace(id: w.workspace_id, label: w.label ?? w.workspace_id, tabs: tabs)
        }
    }
}
