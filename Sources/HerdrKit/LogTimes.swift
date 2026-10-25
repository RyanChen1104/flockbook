import Foundation

/// How long ago, short: "now" under 45 s, then whole minutes, hours and days ("24m", "3h", "2d").
public enum LogAge {
    public static func label(_ d: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s < 45 { return "now" }
        if s < 3600 { return "\(max(1, s / 60))m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

/// When each agent last wrote its session log (the file's modification time): the age on Overview cards.
/// A session is looked at once per `every` at most; its log path is found once and kept. Sessions no longer asked
/// for are dropped. `refresh` may run off the main thread.
public final class LogTimeCache: @unchecked Sendable {
    /// Finds the log (`known`: the path found before) and reads its time. Either may be nil.
    public typealias Look = (_ sessionId: String, _ kind: String, _ known: URL?) -> (URL?, Date?)
    private struct Entry { var url: URL?; var time: Date?; var checked: Date }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let look: Look
    private let every: TimeInterval

    public init(every: TimeInterval = 30, look: @escaping Look = { LogTimeCache.fileTime($0, $1, $2) }) { self.look = look; self.every = every }

    /// `sessions`: (session id, agent kind) of the agents shown now.
    public func refresh(_ sessions: [(String, String)], now: Date) {
        let old = lock.withLock { entries }
        var next: [String: Entry] = [:]
        for (sid, kind) in sessions where next[sid] == nil {
            if let e = old[sid], now.timeIntervalSince(e.checked) < every { next[sid] = e; continue }
            let (url, time) = look(sid, kind, old[sid]?.url)
            next[sid] = Entry(url: url, time: time, checked: now)
        }
        lock.withLock { entries = next }
    }

    public func time(_ sessionId: String) -> Date? { lock.withLock { entries[sessionId]?.time } }
    public var times: [String: Date] { lock.withLock { entries.compactMapValues(\.time) } }

    /// The newest log time of the tab's agents; nil when none has one (a shell tab).
    public static func newest(of tab: Tab, times: [String: Date]) -> Date? {
        tab.panes.compactMap { $0.agent?.sessionId.flatMap { times[$0] } }.max()
    }

    /// The log `SessionLog` tails for this session (`SessionLog.locate`), and its modification time.
    public static func fileTime(_ sid: String, _ kind: String, _ known: URL?) -> (URL?, Date?) {
        guard let url = known ?? SessionLog.locate(agent: kind, sessionId: sid, dir: SessionLog.defaultDir(agent: kind)) else { return (nil, nil) }
        let time = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return (time == nil ? nil : url, time)   // a moved or removed log is looked for again next time
    }
}

/// Overview's sections when it groups by status. Every tab is in one, so the header's tab count is the card count.
public struct OverviewGroups<Row> {
    public var needsYou: [Row] = [], working: [Row] = [], resting: [Row] = []
    public init(_ rows: [Row], tab: (Row) -> Tab) {
        for r in rows {
            switch tab(r).status {
            case .blocked: needsYou.append(r)
            case .working: working.append(r)
            case .done, .idle, .unknown: resting.append(r)   // unknown: a tab with no agent, such as a shell
            }
        }
    }
}
