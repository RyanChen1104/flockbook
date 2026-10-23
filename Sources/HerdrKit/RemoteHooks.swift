import Foundation

// The Claude question hook and the Claude Code status line for a remote herdr. Claude Code runs on the host there, so
// both go into the HOST's Claude Code settings (`~/.claude/settings.json` on the host), and their files live in the
// host's `~/.config/flockbook`:
// - the hook: the same POSIX sh script as on the Mac (`ClaudeQuestionHook.script`), its records next to it;
// - the status line: a POSIX sh wrapper (`RemoteHooks.statusLineScript`) with the contract of `flockbook-statusline`
//   (the Swift wrapper is a macOS program and does not run on a Linux host).
// The settings file changes with the Mac's care (`ClaudeSettingsHook.rewrite`): our entry only, a backup first, read
// again right before the write, written atomically with the old mode, a linked file refused. The app reads the records
// and the saved lines through `RemoteFiles`-style short commands, bounded in size and count.

/// Where the hook and the status line live on a host. All under the host user's home.
public struct RemoteHookPaths: Sendable, Hashable {
    public var home: String
    public init(home: String) { self.home = home }

    /// Claude Code's user settings on the host.
    public var settingsFile: String { home + "/.claude/settings.json" }
    var base: String { home + "/.config/flockbook" }
    public var hookScript: String { base + "/claude-hook/ask-user-question.sh" }
    public var hookRecords: String { base + "/claude-hook/questions" }
    /// Named like the Mac's wrapper, so the settings code knows it as ours (`ClaudeStatusLineSetting.runsWrapper`).
    public var statusWrapper: String { base + "/statusline/" + ClaudeStatusLineSetting.wrapperName }
    public var statusDir: String { base + "/statusline/lines" }

    /// The host's paths; nil when the host does not answer.
    public static func load(_ files: RemoteFiles) async -> RemoteHookPaths? {
        await files.home().map(RemoteHookPaths.init(home:))
    }
}

public enum RemoteHooks {
    /// Settings files over this size are not read.
    static let maxSettingsBytes = 4 << 20

    /// `script` run by /bin/sh on the host, whatever the login shell of the host user is.
    static func sh(_ script: String) -> String { "exec /bin/sh -c " + RemoteHost.quote(script) }

    // MARK: Small files in one command

    /// One file read by `emitFunction`: its name, modification time and bytes.
    struct Frame: Equatable {
        var name: String
        var time: Date
        var data: Data
    }

    /// A sh function `e <name> <path> <max>`: a regular file (not a link) of at most `max` bytes is printed as the
    /// line "<name> <mtime> <length>" and then its bytes. Needs `LC_ALL=C` (lengths in bytes); names have no spaces.
    static let emitFunction = """
        LC_ALL=C; export LC_ALL
        e() {
          [ -f "$2" ] && [ ! -h "$2" ] || return 0
          s=$(wc -c < "$2" 2>/dev/null | tr -d ' ')
          [ -n "$s" ] && [ "$s" -le "$3" ] || return 0
          t=$(stat -c %Y "$2" 2>/dev/null || stat -f %m "$2" 2>/dev/null) || return 0
          c=$(cat "$2" 2>/dev/null; printf x)
          c=${c%x}
          printf '%s %s %s\\n' "$1" "$t" "${#c}"
          printf '%s' "$c"
        }

        """

    /// The frames in a command's output, in order. Stops at the first header that is not "<name> <time> <length>" or
    /// a frame cut short.
    static func frames(_ data: Data) -> [Frame] {
        var out: [Frame] = []
        var i = data.startIndex
        while i < data.endIndex {
            guard let nl = data[i...].firstIndex(of: 0x0a) else { break }
            let head = String(decoding: data[i..<nl], as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false)
            guard head.count == 3, !head[0].isEmpty, let t = Int64(head[1]), let n = Int(head[2]), n >= 0 else { break }
            let start = data.index(after: nl)
            guard data.distance(from: start, to: data.endIndex) >= n else { break }
            let end = data.index(start, offsetBy: n)
            out.append(Frame(name: String(head[0]), time: Date(timeIntervalSince1970: TimeInterval(t)), data: Data(data[start..<end])))
            i = end
        }
        return out
    }

    // MARK: Claude Code's settings file on the host

    /// The file as it is now: missing, or a file with its bytes and mode, or refused (a link, not a regular file, too big).
    struct SettingsFile: Equatable {
        enum Kind: Equatable { case missing, file(mode: String) }
        var kind: Kind
        var data: Data?
    }

    static func readSettings(_ files: RemoteFiles, _ path: String) async throws -> SettingsFile {
        let f = RemoteHost.quote(path)
        let script = """
            f=\(f)
            if [ -h "$f" ]; then printf 'link\\n'
            elif [ -f "$f" ]; then
              s=$(wc -c < "$f" | tr -d ' ') || exit 1
              [ "$s" -le \(maxSettingsBytes) ] || { printf 'big\\n'; exit 0; }
              m=$( (stat -c %a "$f" || stat -f %Lp "$f") 2>/dev/null)
              printf 'file %s\\n' "$m"
              cat "$f" || exit 1
            elif [ -e "$f" ]; then printf 'other\\n'
            else printf 'none\\n'
            fi
            """
        let r = try await files.host.run(sh(script), timeout: files.timeout)
        guard r.ok, let nl = r.stdout.firstIndex(of: 0x0a) else {
            throw HerdrError.socket("reading \(path) on \(files.host.label) failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let head = String(decoding: r.stdout[..<nl], as: UTF8.self).split(separator: " ")
        switch head.first.map(String.init) ?? "" {
        case "none": return SettingsFile(kind: .missing, data: nil)
        case "file":
            let m = head.count > 1 ? String(head[1]) : ""
            let mode = (3...4).contains(m.count) && m.allSatisfy({ ("0"..."7").contains($0) }) ? m : "600"
            return SettingsFile(kind: .file(mode: mode), data: Data(r.stdout[r.stdout.index(after: nl)...]))
        case "link": throw ClaudeSettingsHook.Failure.unexpected("the settings file is a link; change it by hand")
        case "big": throw ClaudeSettingsHook.Failure.unexpected("the settings file is over \(maxSettingsBytes / 1_048_576) MB")
        default: throw ClaudeSettingsHook.Failure.unexpected("the settings file is not a regular file")
        }
    }

    /// The settings on the host as an object; a missing file is `[:]`.
    static func settings(_ files: RemoteFiles, _ path: String) async throws -> [String: Any] {
        try ClaudeSettingsHook.parse(try await readSettings(files, path).data)
    }

    /// `ClaudeSettingsHook.rewrite` for a file on the host: `change` gives the new settings (nil: nothing written). The
    /// old file is backed up next to it (`<name>.<backups>-<time>.bak`, its mode), the file is read again right before
    /// the write and left alone when it changed since, and the new one is written atomically with the old mode.
    /// Returns the backup's path (nil: no old file, or nothing written).
    @discardableResult
    static func rewrite(_ files: RemoteFiles, path: String, now: Date, backups: String = "flockbook",
                        beforeWrite: (@Sendable () async throws -> Void)? = nil,
                        _ change: ([String: Any]) throws -> [String: Any]?) async throws -> String? {
        let first = try await readSettings(files, path)
        guard let new = try change(try ClaudeSettingsHook.parse(first.data)) else { return nil }
        var data = try JSONSerialization.data(withJSONObject: new, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0a)
        try await beforeWrite?()
        guard (try? await readSettings(files, path)) == first else {
            throw ClaudeSettingsHook.Failure.unexpected("the settings file changed meanwhile; try again")
        }
        var backup: String?
        var mode = "600"
        if case .file(let m) = first.kind, let old = first.data {
            mode = m
            let dir = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
            let names = Set(await files.list(dir) ?? [])
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
            let base = name + ".\(backups)-\(f.string(from: now))"
            var b = base + ".bak", n = 2
            while names.contains(b) { b = base + "-\(n).bak"; n += 1 }
            try await files.write(old, to: dir + "/" + b, mode: m)
            backup = dir + "/" + b
            if backups != "flockbook" {
                for gone in prunable(names.union([b]), name: name, backups: backups, keeping: b) { await files.remove(dir + "/" + gone) }
            }
        }
        try await files.write(data, to: path, mode: mode)
        return backup
    }

    /// Of a folder's `names`, the backups `<name>.<backups>-<time>.bak` to remove so that `keptBackups` stay: the first
    /// and the newest, by the time in the name; `keeping` (just written) stays. Other names are left alone.
    static func prunable(_ names: Set<String>, name: String, backups: String, keeping: String) -> [String] {
        let prefix = name + "." + backups + "-"
        func key(_ n: String) -> (String, Int)? {
            guard n.hasPrefix(prefix), let m = n.dropFirst(prefix.count).wholeMatch(of: /(\d{8}-\d{6})(?:-(\d+))?\.bak/) else { return nil }
            return (String(m.1), m.2.flatMap { Int($0) } ?? 1)
        }
        let baks = names.filter { $0 != keeping }.compactMap { n in key(n).map { (n, $0) } }
            .sorted { $0.1 < $1.1 }.map(\.0)
        guard baks.count > ClaudeSettingsHook.keptBackups - 1 else { return [] }
        return Array(baks.dropFirst().dropLast(max(ClaudeSettingsHook.keptBackups - 2, 0)))
    }

    // MARK: The status line wrapper

    /// The status line wrapper for a host: POSIX sh, run by Claude Code as `flockbook-statusline --dir <folder>` with
    /// the session's JSON on stdin. The contract of the Mac's `flockbook-statusline` (`StatusLineWrapper.run`): it runs
    /// the owner's own statusLine command (the text in `<folder>/.original-command`) with the same input and
    /// `FLOCKBOOK_STATUSLINE=1` set, prints its output unchanged (up to `StatusLineWrapper.maxOutput`) and exits with
    /// its status. It saves the input as `<session>.json` (up to `ClaudeStatusInfo.maxBytes`) and the output as
    /// `<session>.out` (up to `StatusLineFolder.maxBytes`, only when the command ended by itself with status 0 or some
    /// output). Over `timeout` seconds the command is stopped (its whole process group where `setsid` exists), its
    /// output so far printed, status 124. No own command: nothing printed, status 0. A folder it cannot write: the
    /// command still runs, nothing is saved. Its own messages go nowhere: Claude Code sees only the owner's output.
    public static func statusLineScript(timeout: Int = Int(StatusLineWrapper.timeout)) -> String {
        #"""
        #!/bin/sh
        # Flockbook: Claude Code's statusLine command on this machine while "Show Claude Code status line" is on.
        #   flockbook-statusline --dir <folder>
        # Runs your own statusLine command (kept in <folder>/.original-command) with the same input, prints its output
        # unchanged and exits with its status, so Claude Code shows what it showed before. Saves the input and the
        # output in <folder> for Flockbook. No own command: prints nothing. A command still running after \#(timeout) s
        # is stopped (status 124).
        [ -n "${\#(StatusLineWrapper.guardName)+x}" ] && exit 0
        [ "${1-}" = --dir ] && [ -n "${2-}" ] || exit 0
        d=$2
        exec 2>/dev/null
        umask 077
        cmd=
        [ -f "$d/.original-command" ] && cmd=$(cat "$d/.original-command")
        case $cmd in *\#(ClaudeStatusLineSetting.wrapperName)*) cmd= ;; esac
        \#(StatusLineWrapper.guardName)=1
        export \#(StatusLineWrapper.guardName)
        mkdir -p "$d"
        in=$(mktemp "$d/.tmp.XXXXXX") || in=
        if [ -z "$in" ]; then
          # Nothing can be saved here: the owner's command still runs, as before.
          [ -n "$cmd" ] || exit 0
          exec /bin/sh -c "$cmd"
        fi
        cat > "$in"
        sid=$(head -c \#(ClaudeStatusInfo.maxBytes) "$in" | tr -d '\r\n' | LC_ALL=C grep -o '"session_id"[[:space:]]*:[[:space:]]*"[A-Za-z0-9_-]*"' | head -n 1 | LC_ALL=C sed 's/^.*"\([A-Za-z0-9_-]*\)"$/\1/')
        [ ${#sid} -le 128 ] || sid=
        save() {
          t=$(mktemp "$d/.tmp.XXXXXX") || return 0
          if head -c "$2" "$1" > "$t" && mv -f "$t" "$d/$3"; then :; else rm -f "$t"; fi
        }
        [ -n "$sid" ] && save "$in" \#(ClaudeStatusInfo.maxBytes) "$sid.json"
        if [ -z "$cmd" ]; then
          [ -n "$sid" ] && save /dev/null 1 "$sid.out"
          rm -f "$in"
          exit 0
        fi
        out=$(mktemp "$d/.tmp.XXXXXX") || { /bin/sh -c "$cmd" < "$in"; st=$?; rm -f "$in"; exit $st; }
        stop=$out.stop
        p=
        w=
        quit() {
          [ -n "$p" ] && { kill -KILL -"$p" || kill -KILL "$p"; }
          [ -n "$w" ] && kill "$w"
          rm -f "$in" "$out" "$stop"
          exit "$1"
        }
        # Claude Code stops a run that a newer one replaces: the owner's command stops too.
        trap 'quit 143' TERM
        trap 'quit 130' INT
        trap 'quit 129' HUP
        # Its own process group where setsid exists, so a stop reaches what it started.
        if command -v setsid >/dev/null; then
          setsid /bin/sh -c "$cmd" < "$in" > "$out" &
        else
          /bin/sh -c "$cmd" < "$in" > "$out" &
        fi
        p=$!
        (
          sleep \#(timeout)
          : > "$stop"
          kill -TERM -"$p" || kill -TERM "$p"
          sleep 1
          kill -KILL -"$p" || kill -KILL "$p"
        ) < /dev/null > /dev/null &
        w=$!
        wait "$p"
        st=$?
        kill "$w"
        [ -f "$stop" ] && st=124
        head -c \#(StatusLineWrapper.maxOutput) "$out"
        if [ "$st" -ne 124 ] && [ -n "$sid" ] && { [ "$st" -eq 0 ] || [ -s "$out" ]; }; then save "$out" \#(StatusLineFolder.maxBytes) "$sid.out"; fi
        rm -f "$in" "$out" "$stop"
        exit "$st"

        """#
    }
}

/// The Claude question hook on a host: the script in the host's `~/.config/flockbook/claude-hook`, our entry in the
/// host's Claude Code settings, and the records the script writes there. Changed only on the owner's click.
public struct RemoteClaudeHook: Sendable {
    public let files: RemoteFiles
    public let paths: RemoteHookPaths
    public init(files: RemoteFiles, paths: RemoteHookPaths) { self.files = files; self.paths = paths }

    /// The command line in the host's settings entry.
    public var command: String { ClaudeSettingsHook.command(scriptPath: paths.hookScript) }

    /// Our entry is in the host's settings file (read-only).
    public func installed() async throws -> Bool {
        ClaudeSettingsHook.installed(try await RemoteHooks.settings(files, paths.settingsFile), command: command)
    }

    /// Install: the script first (mode 700), then our entry (the file backed up). Returns the backup's path on the host
    /// (nil: nothing to change, or no file before).
    @discardableResult
    public func install(now: Date = Date()) async throws -> String? {
        try await files.write(Data(ClaudeQuestionHook.script(recordsDir: paths.hookRecords).utf8), to: paths.hookScript, mode: "700")
        return try await apply(add: true, now: now)
    }

    /// Uninstall: only our entry leaves the host's settings file. The script stays (a running session may still call it).
    @discardableResult
    public func uninstall(now: Date = Date()) async throws -> String? { try await apply(add: false, now: now) }

    private func apply(add: Bool, now: Date) async throws -> String? {
        let command = self.command
        return try await RemoteHooks.rewrite(files, path: paths.settingsFile, now: now) { old in
            let new = add ? try ClaudeSettingsHook.adding(old, command: command) : ClaudeSettingsHook.removing(old, command: command)
            return ClaudeSettingsHook.installed(old, command: command) != ClaudeSettingsHook.installed(new, command: command) ? new : nil
        }
    }

    /// Up to `limit` newest records, in one command. Records over `ClaudeQuestionHook.maxAge` and stray temp files over
    /// an hour old are removed on the way; files not named `<epoch>.<pid>.json` are never read. Nil: the host did not
    /// answer (the last records read stay in use; an empty list would hide a question that is still open).
    public func records(now: Date = Date(), limit: Int = 16) async -> [ClaudeQuestionHook.Record]? {
        let script = RemoteHooks.emitFunction + """
            d=\(RemoteHost.quote(paths.hookRecords))
            [ -d "$d" ] || exit 0
            find "$d" -maxdepth 1 -type f -name '*.json' -mmin +\(Int(ClaudeQuestionHook.maxAge / 60)) -exec rm -f {} + 2>/dev/null
            find "$d" -maxdepth 1 -type f -name '.tmp.*' -mmin +60 -exec rm -f {} + 2>/dev/null
            for n in $(ls -1 "$d" | grep -E '^[0-9]+\\.[0-9]+\\.json$' | sort -t . -k1,1nr -k2,2nr | head -n \(max(limit, 0))); do
              e "$n" "$d/$n" \(ClaudeQuestionHook.maxBytes)
            done
            exit 0
            """
        guard let r = try? await files.host.run(RemoteHooks.sh(script), timeout: files.timeout), r.ok else { return nil }
        return RemoteHooks.frames(r.stdout)
            .filter { now.timeIntervalSince($0.time) <= ClaudeQuestionHook.maxAge }
            .sorted { $0.time > $1.time }
            .compactMap { ClaudeQuestionHook.record($0.data, time: $0.time) }
    }
}

/// The Claude Code status line on a host: the sh wrapper in the host's `~/.config/flockbook/statusline`, ours in the
/// host's Claude Code settings in place of the owner's line (kept in the folder as `.original`, and its command as
/// `.original-command` for the wrapper), and the lines the wrapper saves. `ClaudeStatusLineSetting.apply`'s rules.
public struct RemoteStatusLine: Sendable {
    public let files: RemoteFiles
    public let paths: RemoteHookPaths
    public init(files: RemoteFiles, paths: RemoteHookPaths) { self.files = files; self.paths = paths }

    public var command: String { ClaudeStatusLineSetting.command(wrapper: paths.statusWrapper, dir: paths.statusDir) }

    var originalFile: String { paths.statusDir + "/" + StatusLineFolder.originalName }
    var originalCommandFile: String { paths.statusDir + "/.original-command" }

    /// The kept `.original` object (`on`, `statusLine`); nil: none, or unreadable.
    private func originalObject() async -> [String: Any]? {
        guard let d = await files.read(originalFile, offset: 0, count: StatusLineFolder.maxBytes) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// Keeps the owner's statusLine for the wrapper and for turning ours off (the command first: the wrapper reads it).
    private func saveOriginal(_ line: [String: Any]?, on: Bool) async throws {
        let cmd = StatusLineFolder.ownCommand(line) ?? ""
        try await files.write(Data(cmd.utf8), to: originalCommandFile, mode: "600")
        let o: [String: Any] = ["on": on, "statusLine": line ?? NSNull()]
        try await files.write(try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), to: originalFile, mode: "600")
    }

    private func forgetOriginal() async {
        await files.remove(originalFile)
        await files.remove(originalCommandFile)
    }

    /// The owner's own command, as kept when ours went on (read-only).
    public func ownCommand() async -> String? {
        StatusLineFolder.ownCommand((await originalObject())?["statusLine"] as? [String: Any])
    }

    /// The statusLine command in the host's settings file now (read-only).
    public func currentCommand() async -> String? {
        ((try? await RemoteHooks.settings(files, paths.settingsFile))?["statusLine"] as? [String: Any])?["command"] as? String
    }

    /// On, off, replaced or moved, from the host's settings file and the kept note (read-only).
    public func state() async throws -> ClaudeStatusLineSetting.State {
        let s = try await RemoteHooks.settings(files, paths.settingsFile)
        let wasOn = (await originalObject())?["on"] as? Bool == true
        return ClaudeStatusLineSetting.state(s, command: command, wasOn: wasOn)
    }

    /// On or Off in the host's settings file, as `ClaudeStatusLineSetting.apply` does on the Mac. On writes the wrapper
    /// first (mode 700). Returns the backup's path on the host (nil: nothing written).
    @discardableResult
    public func apply(on: Bool, now: Date = Date()) async throws -> String? {
        let command = self.command
        let backups = ClaudeStatusLineSetting.backupName
        let obj = await originalObject()
        let before = obj?["statusLine"] as? [String: Any], had = obj?["statusLine"] != nil, wasOn = obj?["on"] as? Bool == true
        if on {
            try await files.write(Data(RemoteHooks.statusLineScript().utf8), to: paths.statusWrapper, mode: "700")
            // The owner's line, as found in the file, is kept right before ours goes in (the wrapper runs it from then on).
            let kept = Locked<[String: Any]?>(nil), taken = Locked(false)
            do {
                let backup = try await RemoteHooks.rewrite(files, path: paths.settingsFile, now: now, backups: backups, beforeWrite: { [self] in
                    if taken.get() { try await saveOriginal(kept.get(), on: false) }
                }) { old in
                    if ClaudeStatusLineSetting.isOurs(old["statusLine"], command: command) { return nil }
                    let moved = ClaudeStatusLineSetting.isMoved(old["statusLine"], command: command)
                    let e = try ClaudeStatusLineSetting.enabling(old, command: command)
                    if !moved { kept.set(e.original); taken.set(true) }
                    return e.settings
                }
                // Only "on" is recorded here; a lost line is never recorded as "none".
                if taken.get() || had { try? await saveOriginal(taken.get() ? kept.get() : before, on: true) }
                return backup
            } catch {
                if taken.get() { if had { try? await saveOriginal(before, on: wasOn) } else { await forgetOriginal() } }
                throw error
            }
        }
        let backup = try await RemoteHooks.rewrite(files, path: paths.settingsFile, now: now, backups: backups) { old in
            let line = old["statusLine"]
            guard ClaudeStatusLineSetting.isOurs(line, command: command) || ClaudeStatusLineSetting.isMoved(line, command: command) else { return nil }
            guard had else {
                throw ClaudeSettingsHook.Failure.unexpected("Flockbook's copy of your own status line on the host is gone, so it cannot be put back; set it again with /statusline in Claude Code there")
            }
            return ClaudeStatusLineSetting.disabling(old, command: command, original: before)
        }
        await forgetOriginal()
        await clean()
        return backup
    }

    /// Ours is off already (the owner set another line since): only the kept note goes.
    public func forget() async {
        await forgetOriginal()
        await clean()
    }

    /// A session's saved line, in one command; nil when none, or older than `StatusLineFolder.maxAge`.
    public func record(session: String, now: Date = Date()) async -> StatusLineRecord? {
        guard StatusLineFolder.plainName(session) else { return nil }
        let d = RemoteHost.quote(paths.statusDir)
        let script = RemoteHooks.emitFunction + """
            e json \(d)/\(session).json \(ClaudeStatusInfo.maxBytes)
            e out \(d)/\(session).out \(StatusLineFolder.maxBytes)
            exit 0
            """
        guard let r = try? await files.host.run(RemoteHooks.sh(script), timeout: files.timeout), r.ok else { return nil }
        let f = RemoteHooks.frames(r.stdout)
        guard let j = f.first(where: { $0.name == "json" }), now.timeIntervalSince(j.time) <= StatusLineFolder.maxAge else { return nil }
        let lines = f.first(where: { $0.name == "out" }).map { ANSIText.lines(String(decoding: $0.data, as: UTF8.self)) } ?? []
        return StatusLineRecord(lines: lines, info: ClaudeStatusInfo(json: j.data), time: j.time)
    }

    /// Removes saved lines older than `StatusLineFolder.maxAge` and stray temp files.
    public func clean() async {
        let d = RemoteHost.quote(paths.statusDir)
        let mins = Int(StatusLineFolder.maxAge / 60)
        let script = """
            [ -d \(d) ] || exit 0
            find \(d) -maxdepth 1 -type f \\( -name '*.json' -o -name '*.out' \\) -mmin +\(mins) -exec rm -f {} + 2>/dev/null
            find \(d) -maxdepth 1 -type f -name '.tmp.*' -mmin +60 -exec rm -f {} + 2>/dev/null
            exit 0
            """
        _ = try? await files.host.run(RemoteHooks.sh(script), timeout: files.timeout)
    }
}

/// A host and its hook paths, found once (one round trip for the home folder) and kept.
public final class RemoteHookSite: Sendable {
    public let host: RemoteHost
    public let files: RemoteFiles
    private let found = Locked<RemoteHookPaths?>(nil)

    public init(host: RemoteHost, files: RemoteFiles? = nil) { self.host = host; self.files = files ?? RemoteFiles(host: host) }

    /// The paths, when found already.
    public var known: RemoteHookPaths? { found.get() }

    /// The paths; nil while the host does not answer (asked again next time).
    public func paths() async -> RemoteHookPaths? {
        if let p = found.get() { return p }
        let p = await RemoteHookPaths.load(files)
        if let p { found.set(p) }
        return p
    }

    public func hook() async -> RemoteClaudeHook? { await paths().map { RemoteClaudeHook(files: files, paths: $0) } }
    public func statusLine() async -> RemoteStatusLine? { await paths().map { RemoteStatusLine(files: files, paths: $0) } }
}

/// Reads of a host's files on demand, for views that ask often and synchronously: `value(key)` returns the last
/// result at once (nil: none yet) and starts a new read when that is older than `every` and none runs for the key.
/// Nothing is read while nobody asks; keys not asked for in `forget` are dropped.
public final class RemotePoll<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    struct Entry { var value: Value?; var read = Date.distantPast; var asked = Date(); var running = false }
    private let entries = Locked<[Key: Entry]>([:])
    private let every: TimeInterval
    private let forget: TimeInterval
    private let read: @Sendable (Key) async -> Value?

    /// `read` nil: keep the last value.
    public init(every: TimeInterval, forget: TimeInterval = 600, read: @escaping @Sendable (Key) async -> Value?) {
        self.every = every; self.forget = forget; self.read = read
    }

    public func value(_ key: Key, now: Date = Date()) -> Value? {
        let (v, start) = entries.update { e -> (Value?, Bool) in
            for (k, x) in e where now.timeIntervalSince(x.asked) > forget { e[k] = nil }
            var x = e[key] ?? Entry()
            x.asked = now
            let start = !x.running && now.timeIntervalSince(x.read) >= every
            if start { x.running = true }
            e[key] = x
            return (x.value, start)
        }
        if start {
            let read = read, entries = entries
            Task.detached(priority: .utility) {
                let got = await read(key)
                entries.update { e in
                    var x = e[key] ?? Entry()
                    if let got { x.value = got }
                    x.read = Date(); x.running = false
                    e[key] = x
                }
            }
        }
        return v
    }

    /// Drops what was read: the next `value` reads again (the feature went off, or the host changed).
    public func reset() { entries.set([:]) }
}
