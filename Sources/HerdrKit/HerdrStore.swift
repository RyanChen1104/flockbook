import Foundation
import Observation

@MainActor @Observable
public final class HerdrStore {
    public let session: HerdrSession
    public let client: HerdrClient
    public private(set) var workspaces: [Workspace] = []
    public private(set) var connected = false
    /// The panes there are now, from the last snapshot herdr gave (none: the last tab closed). Nil: no snapshot yet.
    public var knownPanes: Set<String>? {
        snapshotted ? Set(workspaces.flatMap(\.tabs).flatMap(\.panes).map(\.id)) : nil
    }
    /// A snapshot was applied (`workspaces` is herdr's, not the empty start).
    @ObservationIgnored private var snapshotted = false
    /// Why the last snapshot failed, with the next step (`ConnectionCheck`). Nil while connected, or when the socket
    /// accepts but the request fails.
    public private(set) var problem: ConnectionProblem?
    @ObservationIgnored var isPreview = false
    @ObservationIgnored var fuzzState: UInt64 = 0
    @ObservationIgnored var fuzzCounter = 0

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var logs: [String: SessionLog] = [:]
    private var logItems: [String: SessionLog.Snapshot] = [:]
    @ObservationIgnored private var logTasks: [String: Task<Void, Never>] = [:]
    /// Tailed sessions, most recently read first. Beyond `maxLiveLogs` the oldest idle ones are released.
    @ObservationIgnored private var recentLogs: [String] = []
    /// Upper bound of tailed logs. Blocked agents are never released (the inbox reads their permission request).
    public var maxLiveLogs = 8
    /// Sessions whose pane is on screen; they keep the full 2 MB tail, every other log keeps about 256 KB.
    /// The app may set it. While it is nil, the session read last counts as visible.
    @ObservationIgnored private var visibleOverride: Set<String>?
    @ObservationIgnored private var reliefPending = false

    public func setVisibleSessions(_ ids: Set<String>?) { visibleOverride = ids; applyDepth() }

    /// Without `setVisibleSessions`, a log read in the last 2 s counts as visible. (Only "the last one read" made two
    /// panes read in turn swap full/short on every call, and each swap re-parsed 2 MB.)
    @ObservationIgnored private var lastRead: [String: Date] = [:]
    @ObservationIgnored private var demotePending = false
    private func applyDepth() {
        let now = Date()
        let vis = visibleOverride ?? Set(lastRead.filter { now.timeIntervalSince($0.value) < 2 }.keys)
        for (id, log) in logs { log.setFull(vis.contains(id)) }
        scheduleRelief()
        if visibleOverride == nil, !vis.isEmpty, !demotePending {
            demotePending = true
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(2100))
                self?.demotePending = false
                if self?.visibleOverride == nil { self?.applyDepth() }
            }
        }
    }

    /// Hands freed pages back to the system once, shortly after logs were released or trimmed.
    private func scheduleRelief() {
        guard !reliefPending else { return }
        reliefPending = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.reliefPending = false
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    public init(session: HerdrSession) {
        self.session = session
        self.client = HerdrClient(session: session)
        self.resolver = SessionResolver(socketPath: session.socketPath)
    }

    // MARK: - Session fallback

    /// Finds logs for agent panes that herdr reports without a session (read-only; see `SessionResolver`).
    @ObservationIgnored private let resolver: SessionResolver
    /// paneId → log path found by the resolver.
    @ObservationIgnored private var resolved: [String: String] = [:]
    @ObservationIgnored private var resolveTask: Task<Void, Never>?

    /// paneId → the log to show in place of a teammate's log that herdr names (see `SessionResolver.leads`).
    @ObservationIgnored private var swaps: [String: LeadSwap] = [:]

    /// Fills `agent.sessionId` from `resolved` where herdr gave none, and puts the lead's log (or none) in place of
    /// a teammate's log while herdr still names it. Either way the session is not herdr's (`sessionResolved`).
    static func withFallbacks(_ ws: [Workspace], resolved: [String: String], swaps: [String: LeadSwap]) -> [Workspace] {
        guard !resolved.isEmpty || !swaps.isEmpty else { return ws }
        var ws = ws
        for w in ws.indices { for t in ws[w].tabs.indices { for p in ws[w].tabs[t].panes.indices {
            let pane = ws[w].tabs[t].panes[p]
            guard let sid = pane.agent?.sessionId else {
                if pane.agent != nil, let path = resolved[pane.id] {
                    ws[w].tabs[t].panes[p].agent?.sessionId = path
                    ws[w].tabs[t].panes[p].agent?.sessionResolved = true
                }
                continue
            }
            if let s = swaps[pane.id], s.teammate == sid {
                ws[w].tabs[t].panes[p].agent?.sessionId = s.lead
                ws[w].tabs[t].panes[p].agent?.sessionResolved = true
            }
        } } }
        return ws
    }

    static func claims(_ ws: [Workspace], resolved: [String: String]) -> Set<String> { [] }

    /// Starts one resolver pass for the panes that still have no session, and for Claude panes whose session may be
    /// a teammate's log. The snapshot never waits for it.
    private func resolveMissing(_ raw: [Workspace]) {
        guard !isPreview, resolveTask == nil else { return }
        let panes = raw.flatMap(\.tabs).flatMap(\.panes)
        let needs = panes.compactMap { p in
            p.agent.flatMap { $0.sessionId == nil ? SessionResolver.Need(paneId: p.id, kind: $0.kind, cwd: p.cwd) : nil }
        }
        let asks = panes.compactMap { p in
            p.agent.flatMap { a in
                a.kind == "claude" ? a.sessionId.map { SessionResolver.LeadAsk(paneId: p.id, sessionId: $0, cwd: p.cwd) } : nil
            }
        }
        if needs.isEmpty, resolved.isEmpty, asks.isEmpty, swaps.isEmpty { return }
        let claimed = Set(panes.compactMap { $0.agent?.sessionId })
        resolveTask = Task { [weak self, resolver] in
            let found = await resolver.resolve(needs, claimed: claimed)
            let swapped = await resolver.leads(asks, claimed: claimed)
            guard let self else { return }
            self.resolveTask = nil
            guard found != self.resolved || swapped != self.swaps else { return }
            self.resolved = found
            self.swaps = swapped
            self.applySnapshot(self.lastRaw)
        }
    }

    /// The last snapshot as herdr sent it, before `withFallbacks`.
    @ObservationIgnored private var lastRaw: [Workspace] = []

    private func applySnapshot(_ raw: [Workspace]) {
        lastRaw = raw
        let ws = Self.withFallbacks(raw, resolved: resolved, swaps: swaps)
        if ws != workspaces { workspaces = ws }
        syncLogs()
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        loop?.cancel(); loop = nil
        refreshTask?.cancel()
        for t in logTasks.values { t.cancel() }
        logTasks = [:]
        connected = false
    }

    /// Successful snapshots taken so far.
    public private(set) var snapshots = 0
    /// A snapshot herdr gave.
    func took(_ raw: [Workspace]) {
        connected = true
        snapshotted = true
        snapshots += 1
        if problem != nil { problem = nil }
        applySnapshot(raw)
    }

    public func refresh() async {
        do {
            let raw = try await client.snapshot()
            took(raw)
            resolveMissing(raw)
        } catch {
            connected = false
            let session = session
            let found = await Task.detached { ConnectionCheck.diagnose(session: session) }.value
            if found != problem, !connected { problem = found }
        }
    }

    /// Latest parsed conversation for a Claude Code session id. Starts tailing on first call.
    public func conversation(for sessionId: String?) -> [ConversationItem] {
        if isPreview { return PreviewData.conversation }
        guard let sessionId else { return [] }
        track(sessionId)
        touch(sessionId)
        guard let snap = logItems[sessionId] else { return [] }
        return snap.items
    }

    /// The log file `conversation(for:)` reads (picture refs point into it); nil before it is found.
    public func logURL(for sessionId: String?) -> URL? {
        guard !isPreview, let sessionId else { return nil }
        return logs[sessionId]?.url
    }

    /// Whether `conversation(for:)` is still loading, ready (possibly empty), has no log file, or failed.
    /// Starts tailing on first call, like `conversation(for:)`. A nil session id is `.missing`.
    public func conversationState(for sessionId: String?) -> ConversationLoadState {
        if isPreview { return .ready }
        guard let sessionId else { return .missing }
        track(sessionId)
        touch(sessionId)
        return logItems[sessionId]?.load ?? .loading
    }

    /// Claude Code's queue as that session's log has it (`ClaudeQueueLog`). Read with the screen (`QueuedInput.read`).
    public func queuedInLog(for sessionId: String?) -> ClaudeQueueLog {
        guard !isPreview, let sessionId else { return [] }
        return logItems[sessionId]?.queued ?? []
    }

    /// Loads an older segment of that session's log. True while older content remains. `conversation(for:)` grows within one poll.
    @discardableResult
    public func loadEarlier(for sessionId: String?, bytes: Int = 2_000_000) async -> Bool {
        guard !isPreview, let sessionId, let log = logs[sessionId] else { return false }
        return await log.loadEarlier(bytes: bytes)
    }

    /// Same as `loadEarlier(for:)`, addressed by pane. False when the pane is unknown or has no agent session.
    @discardableResult
    public func loadEarlier(paneId: String, bytes: Int = 2_000_000) async -> Bool {
        await loadEarlier(for: Self.sessionId(forPane: paneId, in: workspaces), bytes: bytes)
    }

    public static func sessionId(forPane paneId: String, in workspaces: [Workspace]) -> String? {
        workspaces.lazy.flatMap(\.tabs).flatMap(\.panes).first { $0.id == paneId }?.agent?.sessionId
    }

    func setPreview(workspaces: [Workspace], connected: Bool) {
        self.workspaces = workspaces
        snapshotted = true
        self.connected = connected
        self.isPreview = true
    }

    // MARK: - Live loop

    /// Reconnect: first retry after 100 ms, then doubling up to 1 s. A local Unix socket connect costs microseconds,
    /// so a short cap keeps the gap after a herdr restart under about a second.
    private func run() async {
        var delay: UInt64 = 100_000_000
        while !Task.isCancelled {
            await refresh()
            let poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await self?.refresh()
                }
            }
            defer { poll.cancel() }
            do {
                for try await _ in client.events() {
                    delay = 100_000_000
                    scheduleRefresh()
                }
            } catch {}
            connected = false
            try? await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 1_000_000_000)
        }
    }

    /// The first event refreshes at once; events that arrive while that refresh runs (or within 50 ms after it)
    /// are coalesced into one more refresh. A burst costs at most two snapshots, a single event costs no delay.
    @ObservationIgnored private var refreshAgain = false
    private func scheduleRefresh() {
        guard refreshTask == nil else { refreshAgain = true; return }
        refreshTask = Task { [weak self] in
            await self?.refresh()
            while let self, self.refreshAgain, !Task.isCancelled {
                self.refreshAgain = false
                try? await Task.sleep(nanoseconds: 50_000_000)
                await self.refresh()
            }
            self?.refreshTask = nil
        }
    }

    // MARK: - Session logs

    /// Stop tailing logs of sessions that left the tree.
    private func syncLogs() {
        let live = Set(workspaces.flatMap(\.tabs).flatMap(\.panes).compactMap { $0.agent?.sessionId })
        for (id, t) in logTasks where !live.contains(id) {
            release(id)
        }
        recentLogs.removeAll { !live.contains($0) }
    }

    private func release(_ id: String) {
        logTasks[id]?.cancel(); logTasks[id] = nil; logItems[id] = nil; logs[id] = nil; lastRead[id] = nil
        scheduleRelief()
    }

    private func touch(_ id: String) {
        let wasVisible = lastRead[id].map { Date().timeIntervalSince($0) < 2 } ?? false
        lastRead[id] = Date()
        if recentLogs.first != id {
            recentLogs.removeAll { $0 == id }
            recentLogs.insert(id, at: 0)
        }
        if visibleOverride == nil, !wasVisible { applyDepth() }
        guard recentLogs.count > maxLiveLogs else { return }
        let blocked = Set(workspaces.flatMap(\.tabs).flatMap(\.panes).compactMap(\.agent).filter { $0.status == .blocked }.compactMap(\.sessionId))
        var i = recentLogs.count - 1
        while recentLogs.count > maxLiveLogs, i >= maxLiveLogs {
            let old = recentLogs[i]
            if blocked.contains(old) { i -= 1; continue }
            recentLogs.remove(at: i); release(old); i -= 1
        }
    }

    private func track(_ sessionId: String) {
        guard logTasks[sessionId] == nil else { return }
        let kind = workspaces.lazy.flatMap(\.tabs).flatMap(\.panes).compactMap(\.agent).first { $0.sessionId == sessionId }?.kind
        let log = SessionLog(sessionId: sessionId, agent: kind ?? "claude")
        log.setFull(visibleOverride?.contains(sessionId) ?? true)   // touch() trims it when it is not the visible one
        logs[sessionId] = log
        logTasks[sessionId] = Task { [weak self] in
            for await snap in log.snapshots() {
                self?.logItems[sessionId] = snap
            }
        }
    }
}
