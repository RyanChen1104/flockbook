import Foundation

/// Our status line in Grok Build's `~/.grok/config.toml`, opt-in like Claude Code's (`ClaudeStatusLineSetting`), and
/// changed only on the owner's switch. The file is TOML, edited as text: only the `[ui.status_line]` table's own
/// lines change, the rest of the file stays as it was, byte for byte. On keeps that table's text (in the wrapper's
/// folder, with its type, command or built-in items) and puts ours in its place, with the owner's other keys (padding,
/// refresh_interval); Off puts the kept text back exactly, or takes ours out when they had none. A status line set in
/// another shape (dotted keys, an inline table, a subtable) is refused: nothing is written. Grok reads the table at
/// startup, so a change shows from Grok's next launch. A table Flockbook cannot read is refused: no state, no write.
public enum GrokStatusLineSetting {
    public enum State: Sendable, Hashable { case off, on, replaced, moved }

    static let header = "ui.status_line"
    /// The keys ours sets; the owner's other keys stay in ours.
    static let replaced: Set<String> = ["type", "command", "items"]
    /// Grok's built-in items when `items` is left out (its user guide).
    public static let defaultItems = ["cwd", "model", "context"]

    typealias Failure = ClaudeSettingsHook.Failure

    /// One key of the table: its value and its lines.
    struct Entry {
        var key: String
        var value: Any
        var lines: Range<Int>
    }

    /// The `[ui.status_line]` table: its header line, the lines up to its last key (`end`: after it), and its keys.
    struct Table {
        var start: Int
        var end: Int
        var entries: [Entry]
        func value(_ k: String) -> Any? { entries.first { $0.key == k }?.value }
        var type: String? { value("type") as? String }
        var command: String? { value("command") as? String }
    }

    static func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    /// A table header line: its name with spaces dropped; nil: not a header. A byte order mark before it is skipped.
    static func tableName(_ line: String) -> String? {
        let line = line.hasPrefix("\u{FEFF}") ? String(line.dropFirst()) : line
        guard let m = line.wholeMatch(of: /\s*\[\[?\s*([^\[\]]+?)\s*\]\]?\s*(#.*)?\r?/) else { return nil }
        return String(m.1).filter { !$0.isWhitespace }
    }

    /// Finds the table, refusing a status line set in any other shape. Nil: none.
    static func table(_ ls: [String]) throws -> Table? {
        var current = "", found: Int?, open: String?
        for (i, l) in ls.enumerated() {
            if open != nil {
                // Text of a multi-line string; a header for ui there could be taken for the table.
                if let name = tableName(l), name == "ui" || name.hasPrefix("ui.") {
                    throw Failure.unexpected("config.toml has [\(name)] inside a multi-line string, which Flockbook does not change")
                }
                open = openString(l, open: open)
                continue
            }
            if let name = tableName(l) {
                current = name
                if l.trimmingCharacters(in: .whitespaces).trimmingPrefix("\u{FEFF}").hasPrefix("[["), name == "ui" || name.hasPrefix("ui.") {
                    throw Failure.unexpected("config.toml has [[\(name)]], an array of tables, which Flockbook does not change")
                }
                if name == header {
                    guard found == nil else { throw Failure.unexpected("config.toml has two [ui.status_line] tables") }
                    found = i
                } else if name.contains("status_line") {
                    throw Failure.unexpected("Grok's status line is set as [\(name)], which Flockbook does not change; use a plain [ui.status_line] table")
                }
                continue
            }
            open = openString(l, open: nil)
            let t = (i == 0 ? Substring(l).trimmingPrefix("\u{FEFF}") : Substring(l)).trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            let key = t[..<eq].filter { !$0.isWhitespace && $0 != "\"" && $0 != "'" }
            // ui set at the top level (an inline table cannot take our table after it) or [ui]'s status_line key.
            if (current == "ui" && key.hasPrefix("status_line")) || (current.isEmpty && (key == "ui" || key.hasPrefix("ui."))) {
                throw Failure.unexpected("Grok's status line is set as \"\(t)\", which Flockbook does not change; use a plain [ui.status_line] table")
            }
        }
        guard let start = found else { return nil }
        var entries: [Entry] = [], i = start + 1, end = start + 1
        while i < ls.count, tableName(ls[i]) == nil {
            let t = ls[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { i += 1; continue }
            guard let m = t.wholeMatch(of: /([A-Za-z0-9_-]+)\s*=\s*(.*)/) else {
                throw Failure.unexpected("[ui.status_line] has a line Flockbook cannot read: \(t)")
            }
            var rest = String(m.2), last = i
            let value: Any
            if rest.hasPrefix("\"\"\"") || rest.hasPrefix("'''") {
                throw Failure.unexpected("[ui.status_line] has a multi-line string, which Flockbook does not change")
            } else if rest.hasPrefix("[") {
                // An array of strings, maybe over several lines.
                while true {
                    if let a = try array(rest) { value = a; break }
                    last += 1
                    guard last < ls.count, tableName(ls[last]) == nil else { throw Failure.unexpected("[ui.status_line] has an array Flockbook cannot read") }
                    rest += "\n" + ls[last]
                }
            } else if rest.hasPrefix("\"") || rest.hasPrefix("'") {
                guard let (s, after) = string(Substring(rest)), comment(after) else { throw Failure.unexpected("[ui.status_line] has a value Flockbook cannot read: \(t)") }
                value = s
            } else {
                value = rest.split(separator: "#", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            }
            entries.append(Entry(key: String(m.1), value: value, lines: i..<(last + 1)))
            i = last + 1
            end = i
        }
        return Table(start: start, end: end, entries: entries)
    }

    /// The multi-line string ("\"\"\"" or "'''") still open at the end of `line`: `open`, one open before the line,
    /// or one the line starts. Nil: none. Single-line strings and comments are skipped.
    static func openString(_ line: String, open: String?) -> String? {
        let c = Array(line.unicodeScalars)
        var i = 0, open = open
        func at(_ q: Unicode.Scalar) -> Bool { i + 2 < c.count && c[i] == q && c[i + 1] == q && c[i + 2] == q }
        while i < c.count {
            if let d = open {
                let q = d.unicodeScalars.first!
                if q == "\"", c[i] == "\\" { i += 2; continue }
                if at(q) {
                    i += 3
                    var n = 0   // up to two quote marks of the text right before the end
                    while n < 2, i < c.count, c[i] == q { i += 1; n += 1 }
                    open = nil
                } else { i += 1 }
                continue
            }
            switch c[i] {
            case "#": return nil
            case "\"" where at("\""): open = "\"\"\""; i += 3
            case "'" where at("'"): open = "'''"; i += 3
            case "\"":
                i += 1
                while i < c.count, c[i] != "\"" { i += c[i] == "\\" ? 2 : 1 }
                i += 1
            case "'":
                i += 1
                while i < c.count, c[i] != "'" { i += 1 }
                i += 1
            default: i += 1
            }
        }
        return open
    }

    /// Only spaces or a comment.
    static func comment(_ s: Substring) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.hasPrefix("#")
    }

    /// A basic or literal string at the start of `s`, and what follows it. Read per Unicode scalar, as `quoted`
    /// writes it (a quote mark or backslash followed by a combining mark is still a quote mark or backslash).
    static func string(_ s: Substring) -> (String, Substring)? {
        let u = s.unicodeScalars
        guard let q = u.first, q == "\"" || q == "'" else { return nil }
        var out = String.UnicodeScalarView(), i = u.index(after: u.startIndex)
        while i < u.endIndex {
            let c = u[i]
            if c == q { return (String(out), Substring(u[u.index(after: i)...])) }
            if (c.value < 0x20 && c != "\t") || c.value == 0x7F { return nil }   // control characters: not TOML
            if q == "\"", c == "\\" {
                i = u.index(after: i)
                guard i < u.endIndex else { return nil }
                switch u[i] {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{8}")
                case "f": out.append("\u{C}")
                case "u", "U":
                    var hex = ""
                    for _ in 0..<(u[i] == "u" ? 4 : 8) {
                        i = u.index(after: i)
                        guard i < u.endIndex, u[i].properties.isASCIIHexDigit else { return nil }
                        hex.unicodeScalars.append(u[i])
                    }
                    guard let v = UInt32(hex, radix: 16), let sc = Unicode.Scalar(v) else { return nil }
                    out.append(sc)
                default: return nil   // other escapes: not read
                }
            } else { out.append(c) }
            i = u.index(after: i)
        }
        return nil
    }

    /// An array of strings, its "]" reached; nil: not closed yet. Throws on anything else in it.
    static func array(_ s: String) throws -> [String]? {
        var rest = Substring(s).dropFirst(), items: [String] = []
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == "," }
            if rest.hasPrefix("#") { rest = rest.drop { $0 != "\n" }; continue }
            guard let c = rest.first else { return nil }
            if c == "]" {
                guard comment(rest.dropFirst()) else { throw Failure.unexpected("[ui.status_line] has an array Flockbook cannot read") }
                return items
            }
            guard let (item, after) = string(rest) else { throw Failure.unexpected("[ui.status_line] has an array Flockbook cannot read") }
            items.append(item)
            rest = after
        }
    }

    /// A TOML basic string, escaped per Unicode scalar: a quote mark or backslash followed by a combining mark is
    /// still escaped, and control characters are written as \uXXXX.
    static func quoted(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        out.append("\"")
        for u in s.unicodeScalars {
            switch u {
            case "\"": out.append(contentsOf: "\\\"".unicodeScalars)
            case "\\": out.append(contentsOf: "\\\\".unicodeScalars)
            case "\u{0}"..."\u{1F}", "\u{7F}": out.append(contentsOf: String(format: "\\u%04X", u.value).unicodeScalars)
            default: out.append(u)
            }
        }
        out.append("\"")
        return String(out)
    }

    static func isOurs(_ t: Table?, command: String) -> Bool { t?.command == command && t?.type == "command" }
    static func isMoved(_ t: Table?, command: String) -> Bool {
        guard let c = t?.command else { return false }
        return ClaudeStatusLineSetting.isMoved(["command": c], command: command)
    }
    /// Ours (or an older copy's) with another type: refused, as Flockbook cannot tell what the owner meant.
    static func checkType(_ t: Table?, command: String) throws {
        guard let t, t.command == command || isMoved(t, command: command), t.type != "command" else { return }
        throw Failure.unexpected("[ui.status_line] has Flockbook's command with type \(t.type.map { "\"\($0)\"" } ?? "unset"); set type = \"command\" in ~/.grok/config.toml")
    }

    /// `text` with ours, and the owner's table to keep (nil: ours was in already, or only its path changed).
    /// The kept table: `type` ("builtin", "command" or "none"), `command`, `items`, and `block` (its exact text) or
    /// `tail` (what was added before ours when they had none).
    public static func enabling(_ text: String, command: String) throws -> (text: String, original: [String: Any]?) {
        var ls = lines(text)
        let t = try table(ls)
        try checkType(t, command: command)
        if isOurs(t, command: command) { return (text, nil) }
        if let t, isMoved(t, command: command), let e = t.entries.first(where: { $0.key == "command" }) {
            ls.replaceSubrange(e.lines, with: ["command = " + quoted(command)])
            return (ls.joined(separator: "\n"), nil)
        }
        if let c = t?.command, ClaudeStatusLineSetting.runsWrapper(c) {
            throw Failure.unexpected("Grok's status line runs another copy of Flockbook (\(c)); turn it off in that copy first")
        }
        let ours = ["type = \"command\"", "command = " + quoted(command)]
        guard let t else {
            let tail = text.isEmpty ? "" : text.hasSuffix("\n") ? "\n" : "\n\n"
            let block = (["[" + header + "]"] + ours).joined(separator: "\n") + "\n"
            return (text + tail + block, ["type": "none", "tail": tail])
        }
        var original: [String: Any] = ["block": ls[t.start..<t.end].joined(separator: "\n")]
        switch (t.type ?? "disabled").lowercased() {
        case "builtin":
            original["type"] = "builtin"
            original["items"] = t.value("items") as? [String] ?? defaultItems
        case "command":
            original["type"] = t.command == nil ? "none" : "command"
            if let c = t.command { original["command"] = c }
        default: original["type"] = "none"
        }
        let kept = t.entries.filter { !replaced.contains($0.key) }.flatMap { ls[$0.lines] }
        ls.replaceSubrange(t.start..<t.end, with: [ls[t.start]] + ours + kept)
        return (ls.joined(separator: "\n"), original)
    }

    /// `text` without ours (or an older copy's): the owner's table back as it was, or none. Nil: ours is not in
    /// (the owner set another since), nothing to change. Throws when the kept table is gone.
    public static func disabling(_ text: String, command: String, original: [String: Any]?) throws -> String? {
        var ls = lines(text)
        let found = try table(ls)
        try checkType(found, command: command)
        guard let t = found, isOurs(t, command: command) || isMoved(t, command: command) else { return nil }
        guard let original else {
            throw Failure.unexpected("Flockbook's copy of your own status line is gone, so it cannot be put back; set [ui.status_line] in ~/.grok/config.toml again")
        }
        if let block = original["block"] as? String {
            ls.replaceSubrange(t.start..<t.end, with: lines(block))
            return ls.joined(separator: "\n")
        }
        ls.removeSubrange(t.start..<t.end)
        let out = ls.joined(separator: "\n"), tail = original["tail"] as? String ?? ""
        // Ours is still last in the file: what was added before it goes too.
        return t.end == lines(text).count - 1 && out.hasSuffix(tail) ? String(out.dropLast(tail.count)) : out
    }

    /// `wasOn`: the owner switched ours on and not off since. Throws when the table cannot be read: ours may still be
    /// in it, so it is not "replaced" (Off would forget the owner's kept table).
    public static func state(_ text: String, command: String, wasOn: Bool) throws -> State {
        let t = try table(lines(text))
        try checkType(t, command: command)
        if isOurs(t, command: command) { return .on }
        if isMoved(t, command: command) { return .moved }
        return wasOn ? .replaced : .off
    }

    /// The `[ui.status_line]` table's own lines (nil: none, or the file cannot be read).
    public static func tableText(_ text: String) -> String? {
        let ls = lines(text)
        return (try? table(ls)).flatMap { $0 }.map { ls[$0.start..<$0.end].joined(separator: "\n") }
    }

    /// The table's command now (nil: none, or the file cannot be read).
    public static func currentCommand(_ text: String) -> String? { (try? table(lines(text)))?.command }

    /// Our backups of config.toml: `config.toml.flockbook-statusline-<time>.bak`.
    static let backupName = "flockbook-statusline"

    /// On or Off in Grok's config `file`, keeping the owner's table in `folder`, as `ClaudeStatusLineSetting.apply`
    /// does. Returns the backup (nil: nothing written).
    @discardableResult
    public static func apply(on: Bool, file: URL, command: String, folder: StatusLineFolder, now: Date = Date(),
                             beforeWrite: (() -> Void)? = nil) throws -> URL? {
        if on {
            if let w = ClaudeStatusLineSetting.parts(command)?.wrapper, ClaudeStatusLineSetting.unstable(wrapper: w) {
                throw Failure.unexpected("Flockbook is running from a disk image or a temporary copy; move it to Applications and open it from there")
            }
            var kept: [String: Any]?, taken = false
            let before = folder.original(), had = folder.hasOriginal, wasOn = folder.wasOn
            do {
                let backup = try rewrite(file: file, now: now, beforeWrite: {
                    if taken { try folder.saveOriginal(kept, on: false) }
                    beforeWrite?()
                }) { old in
                    let e = try enabling(old, command: command)
                    if e.text == old { return nil }
                    if let o = e.original { kept = o; taken = true }
                    return e.text
                }
                if taken || had { try? folder.saveOriginal(taken ? kept : before, on: true) }
                return backup
            } catch {
                if taken { if had { try? folder.saveOriginal(before, on: wasOn) } else { folder.forgetOriginal() } }
                throw error
            }
        }
        let original = folder.original()
        let backup = try rewrite(file: file, now: now, beforeWrite: beforeWrite) { old in
            try disabling(old, command: command, original: original)
        }
        folder.forgetOriginal()
        folder.clean()
        return backup
    }

    /// `ClaudeSettingsHook.rewrite` for a text file: a linked file refused, a backup first, read again right before
    /// the write and left alone when it changed since, written atomically with the old mode.
    static func rewrite(file: URL, now: Date, beforeWrite: (() throws -> Void)?, _ change: (String) throws -> String?) throws -> URL? {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: file.path)
        if attrs?[.type] as? FileAttributeType == .typeSymbolicLink { throw Failure.unexpected("config.toml is a link; change it by hand") }
        let original = attrs == nil ? nil : try Data(contentsOf: file)
        var old = ""
        if let original {
            guard let s = String(data: original, encoding: .utf8) else { throw Failure.unexpected("config.toml is not UTF-8 text") }
            old = s
        }
        guard let new = try change(old) else { return nil }
        let mode = attrs?[.posixPermissions] as? Int ?? 0o600
        try beforeWrite?()
        let again = fm.fileExists(atPath: file.path) ? try? Data(contentsOf: file) : nil
        guard again == original, (try? fm.attributesOfItem(atPath: file.path))?[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw Failure.unexpected("config.toml changed meanwhile; try again")
        }
        var backup: URL?
        if let original {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
            let base = file.lastPathComponent + ".\(backupName)-\(f.string(from: now))"
            var b = file.deletingLastPathComponent().appendingPathComponent(base + ".bak")
            var n = 2
            while fm.fileExists(atPath: b.path) { b = file.deletingLastPathComponent().appendingPathComponent(base + "-\(n).bak"); n += 1 }
            try original.write(to: b, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: b.path)
            backup = b
            ClaudeSettingsHook.pruneBackups(of: file, name: backupName, keeping: b)
        } else {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(new.utf8).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        return backup
    }
}

/// Grok's built-in status line, drawn by the wrapper from Grok's JSON while ours is on (Grok's own needs no command,
/// so it cannot run under ours): the owner's items in their order, " │ " between them, without Grok's colours.
public enum GrokBuiltinLine {
    public static func render(_ input: Data, items: [String], now: Date) -> String {
        guard input.count <= ClaudeStatusInfo.maxBytes, let o = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { return "" }
        func dict(_ k: String) -> [String: Any]? { o[k] as? [String: Any] }
        func cut(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }
        // Control characters dropped: the session name may come from the model, and the line goes to Grok's terminal.
        func clean(_ s: String) -> String {
            String(String.UnicodeScalarView(s.unicodeScalars.filter { !($0.value < 0x20 || (0x7F...0x9F).contains($0.value)) }))
        }
        func nonEmpty(_ s: String?) -> String? { s.map(clean).flatMap { $0.isEmpty ? nil : $0 } }
        var parts: [String] = []
        for item in items {
            switch item {
            case "cwd":
                if let d = nonEmpty(dict("workspace")?["current_dir"] as? String ?? o["cwd"] as? String) {
                    parts.append(cut(URL(fileURLWithPath: d).lastPathComponent, 40))
                }
            case "model":
                if let m = nonEmpty(dict("model")?["display_name"] as? String ?? dict("model")?["id"] as? String) { parts.append(cut(m, 30)) }
            case "context":
                if let p = (dict("context_window")?["used_percentage"] as? NSNumber)?.doubleValue, p.isFinite {
                    parts.append("\(Int(min(max(p, 0), 100).rounded()))% ctx")
                }
            case "cost":
                if let c = (dict("cost")?["total_cost_usd"] as? NSNumber)?.doubleValue, c >= 0.005 { parts.append(String(format: "$%.2f", c)) }
            case "turn-timer":
                if let ms = (dict("turn")?["started_at_ms"] as? NSNumber)?.doubleValue {
                    let s = Int(now.timeIntervalSince1970 - ms / 1000)
                    if s >= 3600 { parts.append(String(format: "%dh %02dm", s / 3600, s % 3600 / 60)) }
                    else if s >= 60 { parts.append(String(format: "%dm %02ds", s / 60, s % 60)) }
                    else if s >= 1 { parts.append("\(s)s") }
                }
            case "session-name":
                if let n = nonEmpty(o["session_name"] as? String) { parts.append(cut(n, 40)) }
            default: continue
            }
        }
        return parts.joined(separator: " │ ")
    }
}
