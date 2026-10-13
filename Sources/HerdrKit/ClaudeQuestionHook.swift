import Foundation

/// Claude Code writes an AskUserQuestion call to its log only after the answer, so while the picker is open the
/// question exists only on screen. A PreToolUse hook (matcher AskUserQuestion) sees the call before the picker
/// opens: it saves the hook's JSON (session_id, tool_use_id, tool_input) to a file in the app's own folder, then
/// exits 0 at once. It never blocks or changes the call. The hub binds the picker on screen to the newest record
/// of the agent's session and answers it only when the screen is that record's exact rendering
/// (`QuestionAdapter.claudeExact`); else the phone says "answer on the Mac".
/// The hook is opt-in: only the owner's click in Settings adds it to `~/.claude/settings.json` (`ClaudeSettingsHook`).
public enum ClaudeQuestionHook {
    /// One saved call. `time`: when the hook wrote it (the file's date).
    public struct Record: Sendable, Hashable {
        public var sessionId: String
        public var request: QuestionRequest
        public var time: Date
    }

    /// Hook files over this size are not read (the hook stops writing there too).
    public static let maxBytes = 262_144
    /// Records older than this are not used, and the app removes them.
    public static let maxAge: TimeInterval = 24 * 3600

    /// A hook record from the hook's stdin JSON: a PreToolUse call of AskUserQuestion with a session id, a tool use
    /// id (letters, digits, `_`, `-`) and questions. Anything else: nil.
    public static func record(_ data: Data, time: Date) -> Record? {
        guard data.count <= maxBytes, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              o["hook_event_name"] as? String == "PreToolUse", o["tool_name"] as? String == "AskUserQuestion",
              let sid = o["session_id"] as? String, !sid.isEmpty, sid.count <= 128,
              let id = o["tool_use_id"] as? String, id.wholeMatch(of: /[A-Za-z0-9_-]{1,128}/) != nil,
              let input = o["tool_input"] as? [String: Any], var q = QuestionAdapter.claude(id: id, input: input)
        else { return nil }
        q.headers = []   // a log-like request: every question is known, none is unread
        return Record(sessionId: sid, request: q, time: time)
    }

    /// The question this session's agent asks now, as far as the hook knows: its newest record, when not older than
    /// `maxAge`. An older record of the session never stands in for it. Two newest records at the same time with
    /// different ids: nil (cannot tell which).
    public static func newest(_ records: [Record], session: String, now: Date) -> QuestionRequest? {
        let mine = records.filter { $0.sessionId == session }
        guard let top = mine.max(by: { $0.time < $1.time }), now.timeIntervalSince(top.time) <= maxAge,
              !mine.contains(where: { $0.time == top.time && $0.request.toolUseId != top.request.toolUseId }) else { return nil }
        return top.request
    }

    /// The hook script. `dir`: the records folder. Writes stdin (at most `maxBytes`) to a temp file, then renames it
    /// to `<epoch>.<pid>.json`, mode 600. Prints nothing, always exits 0.
    public static func script(recordsDir dir: String) -> String {
        """
        #!/bin/sh
        # Flockbook: saves Claude Code's AskUserQuestion call so a paired phone can answer the picker.
        # It never blocks or changes the call: no output, always exit 0.
        exec >/dev/null 2>&1
        umask 077
        d=\(shellQuoted(dir))
        mkdir -p "$d" 2>/dev/null || exit 0
        t=$(mktemp "$d/.tmp.XXXXXX" 2>/dev/null) || exit 0
        if head -c \(maxBytes) > "$t" 2>/dev/null; then mv -f "$t" "$d/$(date +%s).$$.json" 2>/dev/null || rm -f "$t"; else rm -f "$t"; fi
        exit 0

        """
    }

    /// `s` in single quotes for /bin/sh.
    public static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The hook's records folder: read, and cleaned of old files. The hook writes; the app only reads and removes
    /// its own old records.
    public struct Folder: Sendable {
        public var url: URL
        public init(url: URL) { self.url = url }

        /// Up to `limit` newest records; files older than `maxAge` (and stray temp files over an hour old) are removed.
        public func records(now: Date = Date(), limit: Int = 64) -> [Record] {
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return [] }
            var files: [(URL, Date, Int)] = []
            for n in names {
                let f = url.appendingPathComponent(n)
                guard let a = try? fm.attributesOfItem(atPath: f.path), a[.type] as? FileAttributeType == .typeRegular,
                      let t = a[.modificationDate] as? Date else { continue }
                let age = now.timeIntervalSince(t)
                if n.hasPrefix(".tmp.") { if age > 3600 { try? fm.removeItem(at: f) }; continue }
                guard n.hasSuffix(".json") else { continue }
                if age > maxAge { try? fm.removeItem(at: f); continue }
                files.append((f, t, (a[.size] as? Int) ?? 0))
            }
            return files.sorted { $0.1 > $1.1 }.prefix(limit).compactMap { file in
                guard file.2 <= maxBytes, let d = try? Data(contentsOf: file.0) else { return nil }
                return record(d, time: file.1)
            }
        }

        /// Writes the hook script to `scriptURL` (mode 700) and makes this folder (mode 700).
        public func writeScript(to scriptURL: URL) throws {
            let fm = FileManager.default
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(script(recordsDir: url.path).utf8).write(to: scriptURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        }
    }
}

/// The hook's entry in Claude Code's settings file. Changed only on the owner's click: Install merges our entry
/// (a backup of the file first; every other key kept; twice = once); Uninstall removes only our entry (and the
/// lists it leaves empty). A file that is not a JSON object, or a `hooks` of an unknown shape, is left alone.
public enum ClaudeSettingsHook {
    public enum Failure: Error, Sendable, Hashable, CustomStringConvertible {
        case notJSON
        case unexpected(String)
        public var description: String {
            switch self {
            case .notJSON: "the settings file is not a JSON object; nothing was changed"
            case .unexpected(let m): "\(m); nothing was changed"
            }
        }
    }

    public static let matcher = "AskUserQuestion"
    public static let timeout = 5

    /// The command line in the entry: the script path, quoted.
    public static func command(scriptPath: String) -> String { ClaudeQuestionHook.shellQuoted(scriptPath) }

    public static func entry(command: String) -> [String: Any] {
        ["matcher": matcher, "hooks": [["type": "command", "command": command, "timeout": timeout] as [String: Any]]]
    }

    /// What Install adds, as shown in Settings.
    public static func preview(command: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["hooks": ["PreToolUse": [entry(command: command)]]],
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Our entry: a hook of type "command" with our command, in a group with our matcher. The same command under
    /// another matcher is someone else's.
    static func isOurs(_ h: Any, command: String) -> Bool {
        guard let h = h as? [String: Any] else { return false }
        return h["type"] as? String == "command" && h["command"] as? String == command
    }
    static func ourGroup(_ g: Any) -> Bool { (g as? [String: Any])?["matcher"] as? String == matcher }

    /// Our entry is in `settings`.
    public static func installed(_ settings: [String: Any], command: String) -> Bool {
        guard let groups = (settings["hooks"] as? [String: Any])?["PreToolUse"] as? [Any] else { return false }
        return groups.contains { g in ourGroup(g) && ((g as? [String: Any])?["hooks"] as? [Any])?.contains { isOurs($0, command: command) } == true }
    }

    /// `settings` with our entry added (unchanged when it is there). `hooks` must be an object, `PreToolUse` a list
    /// of groups, each an object whose `hooks` is a list of objects; else nothing is changed.
    public static func adding(_ settings: [String: Any], command: String) throws -> [String: Any] {
        var s = settings
        var hooks: [String: Any]
        switch s["hooks"] {
        case nil: hooks = [:]
        case let h as [String: Any]: hooks = h
        default: throw Failure.unexpected("\"hooks\" is not an object")
        }
        var pre: [Any]
        switch hooks["PreToolUse"] {
        case nil: pre = []
        case let p as [Any]: pre = p
        default: throw Failure.unexpected("\"hooks.PreToolUse\" is not a list")
        }
        for g in pre {
            guard let group = g as? [String: Any], let hs = group["hooks"] as? [Any], hs.allSatisfy({ $0 is [String: Any] }) else {
                throw Failure.unexpected("an entry in \"hooks.PreToolUse\" has an unknown shape")
            }
        }
        if installed(settings, command: command) { return settings }
        pre.append(entry(command: command))
        hooks["PreToolUse"] = pre
        s["hooks"] = hooks
        return s
    }

    /// `settings` without our entry. A group, `PreToolUse` or `hooks` left empty by that goes too; nothing else changes.
    public static func removing(_ settings: [String: Any], command: String) -> [String: Any] {
        guard installed(settings, command: command), var hooks = settings["hooks"] as? [String: Any],
              let pre = hooks["PreToolUse"] as? [Any] else { return settings }
        var kept: [Any] = []
        for g in pre {
            guard ourGroup(g), var group = g as? [String: Any], let hs = group["hooks"] as? [Any], hs.contains(where: { isOurs($0, command: command) }) else {
                kept.append(g); continue
            }
            let rest = hs.filter { !isOurs($0, command: command) }
            if rest.isEmpty { continue }
            group["hooks"] = rest
            kept.append(group)
        }
        var s = settings
        if kept.isEmpty { hooks.removeValue(forKey: "PreToolUse") } else { hooks["PreToolUse"] = kept }
        if hooks.isEmpty { s.removeValue(forKey: "hooks") } else { s["hooks"] = hooks }
        return s
    }

    /// The settings file as an object; a missing file is `[:]`.
    public static func read(_ file: URL) throws -> [String: Any] {
        try parse(FileManager.default.fileExists(atPath: file.path) ? Data(contentsOf: file) : nil)
    }

    static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09 }) else { return [:] }
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.notJSON }
        return o
    }

    /// Install (`add` true) or Uninstall. Reads the file once, changes only our entry, backs the old file up next to
    /// it (`settings.json.flockbook-<time>.bak`) and writes the new one atomically with the old file's mode. A
    /// linked file is refused (its target and mode are the owner's to change). Right before the write the file is
    /// read again: changed since (another program saved it), nothing is written. The moment between that read and
    /// the rename stays. Returns the backup (nil: nothing to change, nothing written).
    @discardableResult
    public static func apply(add: Bool, file: URL, command: String, now: Date = Date(), beforeWrite: (() -> Void)? = nil) throws -> URL? {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: file.path)   // the link itself, not its target
        if attrs?[.type] as? FileAttributeType == .typeSymbolicLink {
            throw Failure.unexpected("the settings file is a link; change it by hand")
        }
        let original = attrs == nil ? nil : try Data(contentsOf: file)
        let old = try parse(original)
        let new = add ? try adding(old, command: command) : removing(old, command: command)
        guard installed(old, command: command) != installed(new, command: command) else { return nil }
        var data = try JSONSerialization.data(withJSONObject: new, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0a)
        let mode = attrs?[.posixPermissions] as? Int ?? 0o600
        beforeWrite?()
        let again = fm.fileExists(atPath: file.path) ? try? Data(contentsOf: file) : nil
        guard again == original, (try? fm.attributesOfItem(atPath: file.path))?[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw Failure.unexpected("the settings file changed meanwhile; try again")
        }
        var backup: URL?
        if let original {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
            let base = file.lastPathComponent + ".flockbook-\(f.string(from: now))"
            var b = file.deletingLastPathComponent().appendingPathComponent(base + ".bak")
            var n = 2
            while fm.fileExists(atPath: b.path) { b = file.deletingLastPathComponent().appendingPathComponent(base + "-\(n).bak"); n += 1 }
            try original.write(to: b, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: b.path)
            backup = b
        } else {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try data.write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        return backup
    }
}
