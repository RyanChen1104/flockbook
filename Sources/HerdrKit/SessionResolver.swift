import Foundation

/// Finds the log of an agent pane that herdr reports without `agent_session` (seen with Codex on herdr 0.9.1).
/// Read-only: one `ps`, one `lsof`, and the first line of candidate logs. It never sends anything to a pane.
///
/// 1. The pane's process: the env holds `HERDR_PANE_ID` and `HERDR_SOCKET_PATH` (the session), so panes of
///    other herdr sessions never match. The agent is the newest child of the pane's shell.
/// 2. A log file that the agent's process tree holds open (`lsof`). Exactly one, or none.
/// 3. Codex only: the rollout whose `session_meta` cwd is the pane's cwd and that started at or after the agent.
///    Exactly one unclaimed match, or none. It never guesses between two.
///
/// The result is cached per pane and kept while the agent pid stays the same.
public struct LeadSwap: Sendable, Hashable {
    public var teammate: String
    public var lead: String?
    public init(teammate: String, lead: String?) { self.teammate = teammate; self.lead = lead }
}

public actor SessionResolver {
    public struct Proc: Sendable, Hashable {
        public var pid: Int32
        public var ppid: Int32
        public var start: Date
        /// Command line followed by the environment, as `ps -E` prints it.
        public var line: String
    }

    public struct Need: Sendable, Hashable {
        public var paneId: String
        public var kind: String
        public var cwd: String
        public init(paneId: String, kind: String, cwd: String) { self.paneId = paneId; self.kind = kind; self.cwd = cwd }
    }

    private struct Entry { var pid: Int32?; var path: String?; var checked: Date }
    private var cache: [String: Entry] = [:]
    private let socketPath: String
    private let codexDir: String
    private let projectsDir: String
    private let home: String
    /// Unresolved panes are tried again after this; resolved ones are re-checked (pid still the same) after `recheck`.
    private let retry: TimeInterval
    private let recheck: TimeInterval

    public init(socketPath: String, codexDir: String = SessionLog.defaultDir(agent: "codex"),
                projectsDir: String = SessionLog.defaultDir(agent: "claude"), home: String = NSHomeDirectory(),
                retry: TimeInterval = 5, recheck: TimeInterval = 30) {
        self.socketPath = socketPath; self.codexDir = codexDir; self.projectsDir = projectsDir; self.home = home
        self.retry = retry; self.recheck = recheck
    }

    // MARK: - Teammates

    /// A Claude pane whose herdr session may be a teammate's log.
    public struct LeadAsk: Sendable, Hashable {
        public var paneId: String
        public var sessionId: String
        public var cwd: String
        public init(paneId: String, sessionId: String, cwd: String) { self.paneId = paneId; self.sessionId = sessionId; self.cwd = cwd }
    }

    /// Session id → the team when it is a teammate's log, "" when it is not. Only decided logs are kept.
    private var teams: [String: String] = [:]
    /// paneId → the last lead id herdr gave for the pane.
    private var lastLead: [String: String] = [:]
    private var scan = LeadScan()

    /// The panes whose herdr session is a teammate's log, each with the log to show instead (paneId → swap):
    /// the lead id herdr gave last for the pane, else `leadLog`, else none. Every other pane keeps herdr's session.
    public func leads(_ asks: [LeadAsk], claimed: Set<String>) -> [String: LeadSwap] {
        let ids = Set(asks.map(\.paneId))
        lastLead = lastLead.filter { ids.contains($0.key) }
        teams = teams.filter { v in asks.contains { $0.sessionId == v.key } }
        var out: [String: LeadSwap] = [:]
        for a in asks {
            if teams[a.sessionId] == nil, let path = locate(a.sessionId) {
                let head = Self.head(path)
                if let mate = Self.teammateVerdict(head) { teams[a.sessionId] = mate ? Self.teamName(head) ?? "" : "" }
            }
            guard let team = teams[a.sessionId] else { continue }
            guard !team.isEmpty else { lastLead[a.paneId] = a.sessionId; continue }
            if let l = lastLead[a.paneId], !claimed.contains(l) {
                out[a.paneId] = LeadSwap(teammate: a.sessionId, lead: l)
                continue
            }
            // Leads herdr gave other panes are theirs, though herdr names a teammate there now.
            let held = claimed.union(lastLead.filter { $0.key != a.paneId }.values)
            let made = locate(a.sessionId).flatMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.creationDate] as? Date } ?? .distantPast
            let lead = Self.leadLog(projectsDir: projectsDir, cwd: a.cwd, home: home, team: team,
                                    since: made.addingTimeInterval(-600), claimed: held, scan: &scan)
            out[a.paneId] = LeadSwap(teammate: a.sessionId, lead: lead)
        }
        // One lead for two panes is no pane's.
        let twice = Dictionary(grouping: out.values.compactMap(\.lead), by: { $0 }).filter { $0.value.count > 1 }
        for (p, s) in out where s.lead.map({ twice[$0] != nil }) ?? false { out[p]?.lead = nil }
        scan.prune()
        return out
    }

    private func locate(_ id: String) -> String? { SessionLog.locate(agent: "claude", sessionId: id, dir: projectsDir)?.path }

    /// Whether a Claude log is a teammate's: its first message line (`user` or `assistant`) carries `teamName` and
    /// `agentName`. Nil while the log has no message line yet, or when that line is cut off by the read limit and its
    /// keys before `"message":` (where Claude Code writes `teamName`, `agentName` and `type`) do not show a teammate.
    public static func teammateVerdict(_ data: Data) -> Bool? { firstMessage(data).map { $0 != nil } }

    /// The team of a teammate's log, from its first message line.
    public static func teamName(_ data: Data) -> String? { firstMessage(data) ?? nil }

    /// The first message line's team: nil when no line decides, `.some(nil)` for a log that is not a teammate's.
    private static func firstMessage(_ data: Data) -> String?? {
        for line in data.split(separator: 0x0A) {
            if let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                guard let type = o["type"] as? String, type == "user" || type == "assistant" else { continue }
                let team = (o["teamName"] as? String) ?? "", agent = (o["agentName"] as? String) ?? ""
                return .some(team.isEmpty || agent.isEmpty ? nil : team)
            }
            let s = String(decoding: line.prefix(64 << 10), as: UTF8.self)
            let keys = s.range(of: #""message":"#).map { s[..<$0.lowerBound] } ?? s[...]
            guard keys.contains(#""type":"user""#) || keys.contains(#""type":"assistant""#) else { return nil }
            func value(_ k: String) -> String? {
                guard let r = keys.range(of: "\"\(k)\":\"[^\"]+\"", options: .regularExpression) else { return nil }
                return String(keys[r].dropFirst(k.count + 4).dropLast())
            }
            guard let team = value("teamName"), value("agentName") != nil else { return nil }
            return .some(team)
        }
        return nil
    }

    /// The folder under `~/.claude/projects` that Claude Code keeps a cwd's logs in: each character other than an
    /// ASCII letter or digit becomes "-".
    public static func claudeFolder(_ cwd: String) -> String {
        String(cwd.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
    }

    /// The lead's log for a pane whose herdr session is a teammate's of `team`: the one log in the folders of `cwd`
    /// and its ancestors below `home` that names the team (the lead created the team and runs it), is not a
    /// teammate's and is not claimed. None or two or more: nil. Logs not modified since `since` are not read.
    public static func leadLog(projectsDir: String, cwd: String, home: String, team: String, since: Date, claimed: Set<String>, scan: inout LeadScan) -> String? {
        let fm = FileManager.default
        let top = (home as NSString).standardizingPath
        var dir = (cwd as NSString).standardizingPath
        var hits: [String] = []
        while dir.hasPrefix(top + "/") {
            let folder = projectsDir + "/" + claudeFolder(dir)
            for f in ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted() where f.hasSuffix(".jsonl") {
                let p = folder + "/" + f
                guard !isClaimed(p, claimed), let at = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date,
                      at >= since, !scan.isTeammate(p), scan.mentions(p, team) == true else { continue }
                hits.append(p)
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// What the lead search has read of each log, so that a pass reads only the bytes a log added since the last one.
    public struct LeadScan: Sendable {
        private struct Seen { var offset: UInt64 = 0; var tail = Data(); var hit = false }
        private var seen: [String: Seen] = [:]
        /// Path → it is a teammate's log; kept once decided, or once the head is full and still undecided (not one).
        private var mates: [String: Bool] = [:]
        private var touched: Set<String> = []
        private let chunk: Int
        public init(chunk: Int = 4 << 20, budget: Int = 16 << 20) { self.chunk = chunk }
        public var bytesRead: UInt64 { 0 }
        public mutating func endPass() { prune() }

        /// Whether the log at `path` contains `team` (bytes, no JSON parsing).
        public mutating func mentions(_ path: String, _ team: String) -> Bool? {
            let key = team + "\n" + path
            touched.insert(path)
            var s = seen[key] ?? Seen()
            if s.hit { return true }
            guard let fh = FileHandle(forReadingAtPath: path), let size = try? fh.seekToEnd() else { return false }
            defer { try? fh.close() }
            if size < s.offset { s = Seen() }
            let needle = Data(team.utf8)
            try? fh.seek(toOffset: s.offset)
            while !s.hit, let d = try? fh.read(upToCount: chunk), !d.isEmpty {
                let buf = s.tail + d
                s.hit = buf.range(of: needle) != nil
                s.offset += UInt64(d.count)
                s.tail = Data(buf.suffix(needle.count - 1))
            }
            seen[key] = s
            return s.hit
        }

        /// How far `mentions` has read the log for `team`.
        public func offset(_ path: String, _ team: String) -> UInt64 { seen[team + "\n" + path]?.offset ?? 0 }

        mutating func isTeammate(_ path: String) -> Bool {
            touched.insert(path)
            if let m = mates[path] { return m }
            let head = SessionResolver.head(path)
            let v = SessionResolver.teammateVerdict(head)
            if let v { mates[path] = v } else if head.count >= 1 << 20 { mates[path] = false }
            return v == true
        }

        /// Forgets the logs no search looked at since the last prune.
        mutating func prune() {
            let keep = touched
            seen = seen.filter { keep.contains(String($0.key[$0.key.index(after: $0.key.firstIndex(of: "\n")!)...])) }
            mates = mates.filter { keep.contains($0.key) }
            touched = []
        }
    }

    /// The first 1 MB of a file.
    static func head(_ path: String) -> Data {
        guard let fh = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? fh.close() }
        return (try? fh.read(upToCount: 1 << 20)) ?? Data()
    }

    /// Log paths for the given panes (paneId → absolute `.jsonl` path). `claimed`: session ids or paths that other
    /// panes already use; they are never handed out again.
    public func resolve(_ needs: [Need], claimed: Set<String>) -> [String: String] {
        let ids = Set(needs.map(\.paneId))
        cache = cache.filter { ids.contains($0.key) }
        let now = Date()
        let due = needs.filter { n in
            guard let e = cache[n.paneId] else { return true }
            return now.timeIntervalSince(e.checked) >= (e.path == nil ? retry : recheck)
        }
        if !due.isEmpty {
            let procs = Self.processes()
            for n in due {
                let agent = Self.agentProcess(paneId: n.paneId, socketPath: socketPath, procs: procs)
                if let old = cache[n.paneId], old.path != nil, old.pid != nil, old.pid == agent?.pid {
                    cache[n.paneId]?.checked = now
                    continue
                }
                var taken = claimed
                for (p, e) in cache where p != n.paneId { if let path = e.path { taken.insert(path) } }
                let path = agent.flatMap { find(n, agent: $0, procs: procs, claimed: taken) }
                cache[n.paneId] = Entry(pid: agent?.pid, path: path, checked: now)
            }
        }
        var out: [String: String] = [:]
        for n in needs { if let p = cache[n.paneId]?.path { out[n.paneId] = p } }
        return out
    }

    private func find(_ n: Need, agent: Proc, procs: [Proc], claimed: Set<String>) -> String? {
        let open = Self.openFiles(pids: Self.subtree(agent.pid, procs: procs))
        if let p = Self.logPath(openFiles: open, kind: n.kind), !Self.isClaimed(p, claimed) { return p }
        guard n.kind == "codex" else { return nil }
        let c = Self.codexCandidates(dir: codexDir, cwd: n.cwd, after: agent.start).filter { !Self.isClaimed($0, claimed) }
        return c.count == 1 ? c[0] : nil
    }

    // MARK: - Pure parts (checked in HerdrKitChecks)

    /// `ps -E -ww -o pid=,ppid=,lstart=,command=` lines. `lstart` is five words in the C locale.
    public static func parsePS(_ text: String) -> [Proc] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        var out: [Proc] = []
        for raw in text.split(separator: "\n") {
            let w = raw.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
            guard w.count == 8, let pid = Int32(w[0]), let ppid = Int32(w[1]),
                  let start = f.date(from: w[2...6].joined(separator: " ")) else { continue }
            out.append(Proc(pid: pid, ppid: ppid, start: start, line: String(w[7])))
        }
        return out
    }

    /// The agent process of a pane: the newest direct child of the pane's shell (the topmost process that carries
    /// the pane's env). Without a child, the topmost process itself (a pane started with the agent as its command).
    public static func agentProcess(paneId: String, socketPath: String, procs: [Proc]) -> Proc? {
        let pane = " HERDR_PANE_ID=\(paneId) ", sock = " HERDR_SOCKET_PATH=\(socketPath) "
        let mine = procs.filter { ($0.line + " ").contains(pane) && ($0.line + " ").contains(sock) }
        let pids = Set(mine.map(\.pid))
        let roots = mine.filter { !pids.contains($0.ppid) }
        let rootPids = Set(roots.map(\.pid))
        let kids = mine.filter { rootPids.contains($0.ppid) }
        return (kids.isEmpty ? roots : kids).max { $0.start < $1.start }
    }

    public static func subtree(_ pid: Int32, procs: [Proc]) -> [Int32] {
        var out = [pid], i = 0
        while i < out.count {
            let p = out[i]
            out += procs.filter { $0.ppid == p && !out.contains($0.pid) }.map(\.pid)
            i += 1
        }
        return out
    }

    /// The one agent log among open files, or nil when there is none or more than one.
    public static func logPath(openFiles: [String], kind: String) -> String? {
        let home = NSHomeDirectory()
        let hits = Set(openFiles.filter { p in
            guard p.hasSuffix(".jsonl"), !p.contains("/../") else { return false }
            switch kind {
            case "codex": return p.hasPrefix(home + "/.codex/sessions/") && (p as NSString).lastPathComponent.hasPrefix("rollout-")
            case "cursor": return p.hasPrefix(home + "/.cursor/projects/") && p.contains("/agent-transcripts/")
            case "pi": return p.hasPrefix(home + "/.pi/")
            default: return p.hasPrefix(home + "/.claude/projects/")
            }
        })
        return hits.count == 1 ? hits.first : nil
    }

    /// A path counts as claimed when it, or its session id (the file name ends in `<id>.jsonl`), is in `claimed`.
    public static func isClaimed(_ path: String, _ claimed: Set<String>) -> Bool {
        if claimed.contains(path) { return true }
        let name = (path as NSString).lastPathComponent
        return claimed.contains { !$0.isEmpty && !$0.contains("/") && (name == "\($0).jsonl" || name.hasSuffix("-\($0).jsonl")) }
    }

    /// Codex rollouts (`YYYY/MM/DD/rollout-<local time>-<id>.jsonl`) that started at or after `after` (2 s slack:
    /// `lstart` has whole seconds) and whose `session_meta` cwd is `cwd`. Looks at the day folders from `after` on.
    public static func codexCandidates(dir: String, cwd: String, after: Date, now: Date = Date()) -> [String] {
        let fm = FileManager.default
        let cal = Calendar.current
        let names = DateFormatter()
        names.locale = Locale(identifier: "en_US_POSIX")
        names.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let lower = after.addingTimeInterval(-2)
        let want = (cwd as NSString).standardizingPath
        var out: [String] = []
        var day = cal.startOfDay(for: lower)
        var guardDays = 0
        while day <= now, guardDays < 8 {
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let folder = String(format: "%@/%04d/%02d/%02d", dir, c.year ?? 0, c.month ?? 0, c.day ?? 0)
            for f in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where f.hasPrefix("rollout-") && f.hasSuffix(".jsonl") {
                guard let t = names.date(from: String(f.dropFirst(8).prefix(19))), t >= lower else { continue }
                let path = folder + "/" + f
                guard let meta = codexMeta(path), (meta.cwd as NSString).standardizingPath == want, meta.start >= lower else { continue }
                out.append(path)
            }
            day = cal.date(byAdding: .day, value: 1, to: day) ?? now.addingTimeInterval(1)
            guardDays += 1
        }
        return out.sorted()
    }

    /// cwd and start time from a rollout's first line (`session_meta`). Reads at most 1 MB.
    public static func codexMeta(_ path: String) -> (cwd: String, start: Date)? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 1 << 20), let nl = data.firstIndex(of: 0x0A) ?? (data.isEmpty ? nil : data.endIndex),
              let o = try? JSONSerialization.jsonObject(with: data[..<nl]) as? [String: Any],
              o["type"] as? String == "session_meta", let p = o["payload"] as? [String: Any],
              let cwd = p["cwd"] as? String, let ts = p["timestamp"] as? String ?? o["timestamp"] as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let start = iso.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) else { return nil }
        return (cwd, start)
    }

    // MARK: - Subprocesses (read-only)

    static func processes() -> [Proc] {
        parsePS(run("/bin/ps", ["-xE", "-ww", "-o", "pid=,ppid=,lstart=,command="]))
    }

    static func openFiles(pids: [Int32]) -> [String] {
        guard !pids.isEmpty else { return [] }
        let out = run("/usr/sbin/lsof", ["-nP", "-Fn", "-p", pids.map(String.init).joined(separator: ",")])
        return out.split(separator: "\n").compactMap { $0.hasPrefix("n/") ? String($0.dropFirst()) : nil }
    }

    private static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
