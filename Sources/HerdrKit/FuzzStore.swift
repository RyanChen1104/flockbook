import Foundation

// TESTING ONLY. A preview store whose tree changes at random, for the app's `--fuzz` mode.
// It never talks to a herdr server: its session is a named session that does not exist.
extension HerdrStore {
    /// Preview store (dense data) with a seeded random generator for `fuzzStep()`. For tests only.
    public static func previewMutate(seed: UInt64) -> HerdrStore {
        let s = HerdrStore(session: .named("hk-fuzz-none"))
        s.fuzzState = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        s.setPreview(workspaces: HerdrStore.previewDense.workspaces, connected: true)
        return s
    }

    private func fuzzNext(_ n: Int) -> Int {
        fuzzState ^= fuzzState << 13; fuzzState ^= fuzzState >> 7; fuzzState ^= fuzzState << 17
        return Int(fuzzState % UInt64(max(n, 1)))
    }

    private func fuzzID(_ p: String) -> String { fuzzCounter += 1; return "\(p)\(fuzzCounter)" }

    private func fuzzAgent(_ st: AgentStatus) -> Agent { PreviewData.agent("fz-\(fuzzCounter)-dev", st) }

    private static let statuses: [AgentStatus] = [.idle, .done, .working, .blocked, .unknown]

    private func fuzzTab() -> Tab {
        let st = Self.statuses[fuzzNext(4)]
        let panes = (0..<(1 + fuzzNext(2))).map { _ in
            PreviewData.pane(fuzzID("fp"), fuzzNext(5) == 0 ? nil : fuzzAgent(st))
        }
        return Tab(id: fuzzID("ft"), label: fuzzNext(4) == 0 ? "A very long tab name that keeps going and going \(fuzzCounter)" : "Tab \(fuzzCounter)",
                   number: 1, panes: panes, status: AgentStatus.rollup(panes.compactMap { $0.agent?.status }))
    }

    /// One random change to the workspace tree. No-op on a store that was not made by `previewMutate`.
    public func fuzzStep() {
        guard fuzzState != 0 else { return }
        var ws = workspaces
        func renumber(_ w: inout Workspace) { for i in w.tabs.indices { w.tabs[i].number = i + 1 } }
        func rollup(_ t: inout Tab) { t.status = AgentStatus.rollup(t.panes.compactMap { $0.agent?.status }) }
        if ws.isEmpty {   // disconnected-looking state lasts one step
            ws = [Workspace(id: fuzzID("fw"), label: "Refilled", tabs: [fuzzTab()])]
            setPreview(workspaces: ws, connected: true); return
        }
        let wi = fuzzNext(ws.count)
        switch fuzzNext(11) {
        case 0: ws.append(Workspace(id: fuzzID("fw"), label: "WS \(fuzzCounter) · Long name here", tabs: (0..<fuzzNext(4)).map { _ in fuzzTab() }))
        case 1: if ws.count > 1 || fuzzNext(10) == 0 { ws.remove(at: wi) }
        case 2: ws[wi].tabs.append(fuzzTab())
        case 3: if !ws[wi].tabs.isEmpty { ws[wi].tabs.remove(at: fuzzNext(ws[wi].tabs.count)) }
        case 4: if !ws[wi].tabs.isEmpty {
            let ti = fuzzNext(ws[wi].tabs.count)
            ws[wi].tabs[ws[wi].tabs.count > 0 ? ti : 0].panes.append(PreviewData.pane(fuzzID("fp"), fuzzAgent(.idle)))
            rollup(&ws[wi].tabs[ti])
        }
        case 5: if !ws[wi].tabs.isEmpty {
            let ti = fuzzNext(ws[wi].tabs.count)
            if ws[wi].tabs[ti].panes.count > 1 { ws[wi].tabs[ti].panes.remove(at: fuzzNext(ws[wi].tabs[ti].panes.count)); rollup(&ws[wi].tabs[ti]) }
        }
        case 6, 7, 8: if !ws[wi].tabs.isEmpty {
            let ti = fuzzNext(ws[wi].tabs.count)
            let pi = fuzzNext(ws[wi].tabs[ti].panes.count)
            if var a = ws[wi].tabs[ti].panes[pi].agent { a.status = Self.statuses[fuzzNext(5)]; ws[wi].tabs[ti].panes[pi].agent = a }
            rollup(&ws[wi].tabs[ti])
        }
        case 9: if !ws[wi].tabs.isEmpty { ws[wi].tabs[fuzzNext(ws[wi].tabs.count)].label = fuzzNext(2) == 0 ? "" : "Renamed \(fuzzCounter)" }
        default: if fuzzNext(12) == 0 { ws = [] }
        }
        for i in ws.indices { renumber(&ws[i]) }
        setPreview(workspaces: ws, connected: fuzzNext(15) != 0)
    }
}
