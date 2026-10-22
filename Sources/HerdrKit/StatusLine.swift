import Foundation

// Claude Code's status line, opt-in (Settings > Agents). Claude Code runs our wrapper (`flockbook-statusline`) as its
// statusLine command. The wrapper saves the JSON Claude Code gives it, runs the owner's own statusLine command with the
// same input, prints that command's output unchanged and saves a copy (`StatusLineWrapper`). The app reads the saved
// line of each agent session (`StatusLineFolder`) and shows it under the composer and on the phone. Flockbook itself
// never runs the owner's command: only Claude Code does, through the wrapper.

/// A piece of a status line in one style. Colours are `#rrggbb`.
public struct StyledRun: Hashable, Sendable, Codable, CustomStringConvertible {
    public var text: String
    public var fg: String?
    public var bg: String?
    public var bold: Bool
    public var dim: Bool
    public var italic: Bool
    public var underline: Bool

    public init(_ text: String, fg: String? = nil, bg: String? = nil, bold: Bool = false, dim: Bool = false, italic: Bool = false, underline: Bool = false) {
        self.text = text; self.fg = fg; self.bg = bg; self.bold = bold; self.dim = dim; self.italic = italic; self.underline = underline
    }

    var style: Style { Style(fg: fg, bg: bg, bold: bold, dim: dim, italic: italic, underline: underline) }

    struct Style: Hashable {
        var fg: String?, bg: String?
        var bold = false, dim = false, italic = false, underline = false
    }

    private enum K: String, CodingKey { case text, fg, bg, bold, dim, italic, underline }

    // Compact: a false flag is left out.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(fg, forKey: .fg)
        try c.encodeIfPresent(bg, forKey: .bg)
        if bold { try c.encode(true, forKey: .bold) }
        if dim { try c.encode(true, forKey: .dim) }
        if italic { try c.encode(true, forKey: .italic) }
        if underline { try c.encode(true, forKey: .underline) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        text = try c.decode(String.self, forKey: .text)
        fg = try c.decodeIfPresent(String.self, forKey: .fg)
        bg = try c.decodeIfPresent(String.self, forKey: .bg)
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        dim = try c.decodeIfPresent(Bool.self, forKey: .dim) ?? false
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false
    }

    public var description: String {
        var s = "\"\(text)\""
        if let fg { s += " fg \(fg)" }
        if let bg { s += " bg \(bg)" }
        for (on, n) in [(bold, "bold"), (dim, "dim"), (italic, "italic"), (underline, "underline")] where on { s += " " + n }
        return s
    }
}

/// Terminal text with ANSI SGR colours to styled runs, line by line. Other escape sequences and control characters are
/// dropped (an OSC 8 link keeps its text); a style goes on over a newline, as in a terminal.
public enum ANSIText {
    public static let maxLines = 8
    /// Characters per line kept.
    public static let maxColumns = 400

    /// The 16 basic colours (xterm's).
    public static let basic = ["#000000", "#cd0000", "#00cd00", "#cdcd00", "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
                               "#7f7f7f", "#ff0000", "#00ff00", "#ffff00", "#5c5cff", "#ff00ff", "#00ffff", "#ffffff"]

    static func hex(_ r: Int, _ g: Int, _ b: Int) -> String { String(format: "#%02x%02x%02x", r, g, b) }

    /// xterm's 256 colours; nil out of range.
    static func color256(_ n: Int) -> String? {
        switch n {
        case 0..<16: return basic[n]
        case 16..<232:
            let levels = [0, 95, 135, 175, 215, 255], i = n - 16
            return hex(levels[i / 36], levels[i / 6 % 6], levels[i % 6])
        case 232..<256: let v = 8 + 10 * (n - 232); return hex(v, v, v)
        default: return nil
        }
    }

    public static func lines(_ text: String) -> [[StyledRun]] {
        var out: [[StyledRun]] = []
        var line: [StyledRun] = []
        var style = StyledRun.Style()
        var buf = ""
        func flush() {
            guard !buf.isEmpty else { return }
            if let last = line.last, last.style == style { line[line.count - 1].text += buf }
            else { line.append(StyledRun(buf, fg: style.fg, bg: style.bg, bold: style.bold, dim: style.dim, italic: style.italic, underline: style.underline)) }
            buf = ""
        }
        func endLine() {
            flush()
            out.append(line); line = []
        }
        let s = Array(text.unicodeScalars)
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "\u{1B}" {
                i += 1
                guard i < s.count else { break }
                switch s[i] {
                case "[":
                    // CSI: parameters, intermediates, one final byte. Only `m` (SGR) changes anything.
                    var j = i + 1
                    while j < s.count, (0x30...0x3F).contains(s[j].value) { j += 1 }
                    let params = String(String.UnicodeScalarView(s[(i + 1)..<j]))
                    while j < s.count, (0x20...0x2F).contains(s[j].value) { j += 1 }
                    guard j < s.count, (0x40...0x7E).contains(s[j].value) else { i = s.count; continue }
                    if s[j] == "m", (i + 1..<j).allSatisfy({ s[$0] != "?" && s[$0] != ">" && s[$0] != "<" && s[$0] != "=" }) {
                        flush()
                        sgr(params, &style)
                    }
                    i = j + 1
                case "]", "P", "X", "^", "_":
                    // A string (OSC, DCS…) up to BEL or ESC \: dropped; the text after it stays.
                    var j = i + 1
                    while j < s.count, s[j] != "\u{07}", !(s[j] == "\u{1B}" && j + 1 < s.count && s[j + 1] == "\\") { j += 1 }
                    i = j < s.count && s[j] == "\u{07}" ? j + 1 : j + 2
                default:
                    var j = i
                    while j < s.count, (0x20...0x2F).contains(s[j].value) { j += 1 }
                    i = j + 1
                }
                continue
            }
            i += 1
            switch c {
            case "\n": endLine()
            case "\t": buf.unicodeScalars.append(" ")
            case _ where c.value < 0x20 || (0x7F...0x9F).contains(c.value): break
            default: buf.unicodeScalars.append(c)
            }
        }
        if !buf.isEmpty || !line.isEmpty { endLine() }
        return out.lazy.map(cut).filter { !$0.isEmpty }.prefix(maxLines).map { $0 }
    }

    /// The line's first `maxColumns` characters.
    static func cut(_ line: [StyledRun]) -> [StyledRun] {
        var left = maxColumns
        var kept: [StyledRun] = []
        for r in line where left > 0 {
            var r = r
            if r.text.count > left { r.text = String(r.text.prefix(left)) }
            left -= r.text.count
            kept.append(r)
        }
        return kept
    }

    static func sgr(_ params: String, _ st: inout StyledRun.Style) {
        let p = params.isEmpty ? [0] : params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var i = 0
        while i < p.count {
            let n = p[i]
            switch n {
            case 0: st = StyledRun.Style()
            case 1: st.bold = true
            case 2: st.dim = true
            case 3: st.italic = true
            case 4: st.underline = true
            case 22: st.bold = false; st.dim = false
            case 23: st.italic = false
            case 24: st.underline = false
            case 30...37: st.fg = basic[n - 30]
            case 39: st.fg = nil
            case 40...47: st.bg = basic[n - 40]
            case 49: st.bg = nil
            case 90...97: st.fg = basic[n - 90 + 8]
            case 100...107: st.bg = basic[n - 100 + 8]
            case 38, 48:
                // 38;5;n or 38;2;r;g;b. Cut or out of range: the rest of the sequence is dropped.
                var color: String?
                if i + 2 < p.count, p[i + 1] == 5 { color = color256(p[i + 2]); i += 2 }
                else if i + 4 < p.count, p[i + 1] == 2, [p[i + 2], p[i + 3], p[i + 4]].allSatisfy({ (0...255).contains($0) }) {
                    color = hex(p[i + 2], p[i + 3], p[i + 4]); i += 4
                }
                guard let color else { return }
                if n == 38 { st.fg = color } else { st.bg = color }
            default: break
            }
            i += 1
        }
    }

    public static func plain(_ lines: [[StyledRun]]) -> String {
        lines.map { $0.map(\.text).joined() }.joined(separator: "\n")
    }
}

/// What the status line command's JSON says about the session: model, effort, Claude Code's own cost estimate and
/// context use. Nil without a session id that is a plain name (letters, digits, `_`, `-`).
public struct ClaudeStatusInfo: Codable, Hashable, Sendable {
    public var session: String
    public var model: String?
    public var effort: String?
    /// Claude Code's estimate of the session's cost so far, in US dollars.
    public var costUSD: Double?
    public var contextPercent: Int?
    public var contextSize: Int?

    public static let maxBytes = 262_144

    public init?(json: Data) {
        guard json.count <= Self.maxBytes, let o = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let sid = o["session_id"] as? String, StatusLineFolder.plainName(sid) else { return nil }
        session = sid
        let m = o["model"] as? [String: Any]
        model = (m?["display_name"] as? String ?? m?["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        effort = ((o["effort"] as? [String: Any])?["level"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        costUSD = ((o["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber)?.doubleValue
        let ctx = o["context_window"] as? [String: Any]
        contextPercent = (ctx?["used_percentage"] as? NSNumber).map { Int($0.doubleValue.rounded()) }
        contextSize = (ctx?["context_window_size"] as? NSNumber)?.intValue
    }

    /// "Opus 5.5 · high · ctx 37% · $0.42": what is known.
    public var summary: String {
        var parts: [String] = []
        if let model { parts.append(model) }
        if let effort { parts.append(effort) }
        if let contextPercent { parts.append("ctx \(contextPercent)%") }
        if let costUSD { parts.append(String(format: "$%.2f", costUSD)) }
        return parts.joined(separator: " · ")
    }
}

/// One session's saved status line: the owner's command's output as styled lines, and the JSON's facts.
public struct StatusLineRecord: Hashable, Sendable {
    public var lines: [[StyledRun]]
    public var info: ClaudeStatusInfo?
    public var time: Date
    public init(lines: [[StyledRun]], info: ClaudeStatusInfo?, time: Date) { self.lines = lines; self.info = info; self.time = time }

    /// No own line and no facts: nothing to show.
    public var isEmpty: Bool { lines.isEmpty && (info?.tags.isEmpty ?? true) }
}

/// One tag of the status row over the composer: what Claude Code's JSON says, one fact each.
public struct StatusTag: Hashable, Sendable {
    public enum Kind: String, Sendable { case model, effort, context, cost }
    public var kind: Kind
    public var text: String
    /// What VoiceOver says.
    public var spoken: String
    /// The context used, for its bar.
    public var percent: Int?
    /// The context is nearly full (`warnPercent` and up): orange.
    public var warn: Bool

    public static let warnPercent = 80

    /// The orange of a full context, light and dark (text on the tag: 4.5:1 or more).
    public static func warnHex(dark: Bool) -> String { dark ? "#ffa04a" : "#a04b00" }
    /// The tag's fill over the pane, light and dark.
    public static func tagHex(dark: Bool) -> String { dark ? "#2e2e2e" : "#f0f0f0" }

    /// WCAG contrast of two `#rrggbb` colours.
    public static func contrast(_ a: String, _ b: String) -> Double {
        func lum(_ hex: String) -> Double {
            guard hex.count == 7, hex.first == "#", let v = UInt32(hex.dropFirst(), radix: 16) else { return 0 }
            func lin(_ c: UInt32) -> Double { let x = Double(c & 0xff) / 255; return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(v >> 16) + 0.7152 * lin(v >> 8) + 0.0722 * lin(v)
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

extension ClaudeStatusInfo {
    /// The row's tags: model, effort, context, cost; a field Claude Code did not send has none.
    public var tags: [StatusTag] {
        var out: [StatusTag] = []
        if let model { out.append(StatusTag(kind: .model, text: model, spoken: "Model \(model)", percent: nil, warn: false)) }
        if let effort { out.append(StatusTag(kind: .effort, text: effort, spoken: "Effort \(effort)", percent: nil, warn: false)) }
        if let p = contextPercent {
            out.append(StatusTag(kind: .context, text: "ctx \(p)%", spoken: "Context \(p)% used", percent: p, warn: p >= StatusTag.warnPercent))
        }
        if let c = costUSD {
            let d = String(format: "$%.2f", c)
            out.append(StatusTag(kind: .cost, text: "\(d) est.", spoken: "Session cost about \(d), an estimate", percent: nil, warn: false))
        }
        return out
    }
}

/// The status row: one line of tags, then the chevron.
public enum StatusTagRow {
    public struct Fit: Hashable, Sendable {
        public var shown: Int
        public var chevron: Bool
        public init(shown: Int, chevron: Bool) { self.shown = shown; self.chevron = chevron }
    }

    /// How many tags fit on one row, in order, and whether the chevron shows: when a tag is left out, or `more` (own
    /// lines that only the open view shows). The chevron takes its width and a spacing.
    public static func fit(widths: [CGFloat], chevron: CGFloat, spacing: CGFloat, available: CGFloat, more: Bool) -> Fit {
        var used: CGFloat = 0, all = 0
        for w in widths {
            let next = used + (all > 0 ? spacing : 0) + w
            if next > available { break }
            used = next; all += 1
        }
        if all == widths.count && !more { return Fit(shown: all, chevron: false) }
        // The chevron needs its room: drop tags from the end until it fits.
        var shown = all
        while shown > 0 {
            let row = widths.prefix(shown).reduce(0, +) + CGFloat(shown - 1) * spacing
            if row + spacing + chevron <= available { break }
            shown -= 1
        }
        return Fit(shown: shown, chevron: true)
    }
}

/// The wrapper's folder in the app's support folder: per session `<id>.json` (the input) and `<id>.out` (the owner's
/// command's output), and `.original` (the owner's statusLine from Claude Code's settings, and whether ours is on).
/// The wrapper writes; the app reads and removes old records.
public struct StatusLineFolder: Sendable {
    public var url: URL
    public init(url: URL) { self.url = url }

    /// Saved output over this size is cut; files over it are not read.
    public static let maxBytes = 65_536
    /// Records older than this are not shown, and `clean` removes them.
    public static let maxAge: TimeInterval = 24 * 3600
    static let originalName = ".original"

    static func plainName(_ s: String) -> Bool { s.wholeMatch(of: /[A-Za-z0-9_-]{1,128}/) != nil }

    func file(_ session: String, _ ext: String) -> URL { url.appendingPathComponent("\(session).\(ext)") }

    private func write(_ data: Data, to f: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = url.appendingPathComponent(".tmp.\(getpid()).\(UUID().uuidString.prefix(8))")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard rename(tmp.path, f.path) == 0 else { try? fm.removeItem(at: tmp); throw CocoaError(.fileWriteUnknown) }
    }

    /// Saves one run: the input and the output (cut at `maxBytes`). Errors are ignored: saving never changes what the
    /// wrapper prints.
    public func save(input: Data, output: Data, session: String) {
        guard Self.plainName(session) else { return }
        try? write(input.prefix(ClaudeStatusInfo.maxBytes), to: file(session, "json"))
        try? write(output.prefix(Self.maxBytes), to: file(session, "out"))
    }

    /// The session's saved line; nil when none, or older than `maxAge`.
    public func record(session: String, now: Date = Date()) -> StatusLineRecord? {
        guard Self.plainName(session) else { return nil }
        let fm = FileManager.default
        let j = file(session, "json"), o = file(session, "out")
        guard let a = try? fm.attributesOfItem(atPath: j.path), a[.type] as? FileAttributeType == .typeRegular,
              let t = a[.modificationDate] as? Date, now.timeIntervalSince(t) <= Self.maxAge,
              (a[.size] as? Int ?? 0) <= ClaudeStatusInfo.maxBytes, let input = try? Data(contentsOf: j) else { return nil }
        var lines: [[StyledRun]] = []
        if let b = try? fm.attributesOfItem(atPath: o.path), b[.type] as? FileAttributeType == .typeRegular,
           (b[.size] as? Int ?? 0) <= Self.maxBytes, let out = try? Data(contentsOf: o) {
            lines = ANSIText.lines(String(decoding: out, as: UTF8.self))
        }
        return StatusLineRecord(lines: lines, info: ClaudeStatusInfo(json: input), time: t)
    }

    /// Removes records older than `maxAge` and stray temp files.
    public func clean(now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return }
        for n in names where n.hasSuffix(".json") || n.hasSuffix(".out") || n.hasPrefix(".tmp.") {
            let f = url.appendingPathComponent(n)
            guard let t = (try? fm.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date else { continue }
            if now.timeIntervalSince(t) > (n.hasPrefix(".tmp.") ? 3600 : Self.maxAge) { try? fm.removeItem(at: f) }
        }
    }

    // MARK: The owner's statusLine

    private var originalFile: URL { url.appendingPathComponent(Self.originalName) }

    private func originalObject() -> [String: Any]? {
        guard let d = try? Data(contentsOf: originalFile) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// Keeps the owner's statusLine (nil: they had none) for the wrapper and for turning ours off; `on`: ours is in
    /// Claude Code's settings.
    public func saveOriginal(_ line: [String: Any]?, on: Bool = true) {
        let o: [String: Any] = ["on": on, "statusLine": line ?? NSNull()]
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        try? write(d, to: originalFile)
    }

    /// The owner's statusLine as it was before ours went in; nil: none.
    public func original() -> [String: Any]? { originalObject()?["statusLine"] as? [String: Any] }

    /// Ours was put in the settings and not taken out by the owner's switch since.
    public var wasOn: Bool { originalObject()?["on"] as? Bool == true }

    /// Ours is off: the kept statusLine goes.
    public func forgetOriginal() { try? FileManager.default.removeItem(at: originalFile) }

    /// The owner's own command, when their statusLine is a command.
    public func originalCommand() -> String? {
        guard let o = original(), (o["type"] as? String ?? "command") == "command", let c = o["command"] as? String,
              !c.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return c
    }
}

/// What the wrapper does for one run of Claude Code's statusLine command.
public enum StatusLineWrapper {
    public struct Result: Sendable { public var output: Data; public var status: Int32 }

    /// Longest an owner's command may run before the wrapper stops it.
    public static let timeout: TimeInterval = 10
    /// Output read from the owner's command at most (all of it is printed; `StatusLineFolder.maxBytes` is saved).
    public static let maxOutput = 1 << 20
    /// The process group of the running command, for the wrapper's signal handler (`installSignalHandlers`).
    nonisolated(unsafe) static var running: pid_t = 0

    /// Saves the input, runs the owner's command (from `dir`'s `.original`) with the same input on stdin and the
    /// given environment, and returns its output and exit status, as Claude Code would have had them. No own command:
    /// nothing, status 0. Over `timeout`: the command's process group is stopped, its output so far kept, status 124.
    /// Saving never changes the output.
    public static func run(input: Data, dir: URL, timeout: TimeInterval = timeout, environment: [String: String]? = nil) -> Result {
        let folder = StatusLineFolder(url: dir)
        let session = ClaudeStatusInfo(json: input)?.session
        if let session { folder.save(input: input, output: Data(), session: session) }
        var result = Result(output: Data(), status: 0)
        if let cmd = folder.originalCommand() {
            result = spawn(cmd, input: input, timeout: timeout, environment: environment ?? ProcessInfo.processInfo.environment)
        }
        if let session { folder.save(input: input, output: result.output, session: session) }
        return result
    }

    /// Claude Code stops a run that a newer one replaces: SIGTERM, SIGINT and SIGHUP stop the owner's command too.
    public static func installSignalHandlers() {
        for s in [SIGTERM, SIGINT, SIGHUP] {
            signal(s) { sig in
                let p = StatusLineWrapper.running
                if p > 0 { kill(-p, SIGKILL) }
                _exit(128 + sig)
            }
        }
    }

    static func spawn(_ cmd: String, input: Data, timeout: TimeInterval, environment: [String: String]) -> Result {
        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0 else { return Result(output: Data(), status: 127) }
        guard pipe(&outPipe) == 0 else { close(inPipe[0]); close(inPipe[1]); return Result(output: Data(), status: 127) }
        for fd in [inPipe[1], outPipe[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_addclose(&actions, inPipe[0])
        posix_spawn_file_actions_addclose(&actions, outPipe[1])
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Its own process group, so a stop reaches what it started; default signal handling in the child.
        posix_spawnattr_setpgroup(&attr, 0)
        var dflt = sigset_t(); sigemptyset(&dflt)
        for s in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&dflt, s) }
        posix_spawnattr_setsigdefault(&attr, &dflt)
        var none = sigset_t(); sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let args = ["/bin/sh", "-c", cmd]
        let env = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let rc = withCStrings(args) { argv in withCStrings(env) { envp in posix_spawn(&pid, "/bin/sh", &actions, &attr, argv, envp) } }
        close(inPipe[0]); close(outPipe[1])
        guard rc == 0 else { close(inPipe[1]); close(outPipe[0]); return Result(output: Data(), status: 127) }
        running = pid

        // The input goes in from another thread: a command that does not read it must not block us.
        let writer = inPipe[1]
        let bytes = input
        Thread.detachNewThread {
            signal(SIGPIPE, SIG_IGN)
            bytes.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = Darwin.write(writer, raw.baseAddress! + off, raw.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
            close(writer)
        }

        var out = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false, exited = false, status: Int32 = 0
        var buf = [UInt8](repeating: 0, count: 16_384)
        var fds = pollfd(fd: outPipe[0], events: Int16(POLLIN), revents: 0)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { timedOut = true; break }
            // Once the command exited, what it left running gets a moment more to finish writing, no more.
            let wait = exited ? min(left, 0.05) : min(left, 0.1)
            let r = poll(&fds, 1, Int32(wait * 1000) + 1)
            if r > 0 {
                let n = read(outPipe[0], &buf, buf.count)
                if n <= 0 { break }
                if out.count < maxOutput { out.append(contentsOf: buf[0..<min(n, maxOutput - out.count)]) }
                continue
            }
            if r < 0, errno != EINTR { break }
            if exited { break }
            var st: Int32 = 0
            if waitpid(pid, &st, WNOHANG) == pid { exited = true; status = st }
        }
        close(outPipe[0])
        if timedOut || !exited {
            if timedOut {
                kill(-pid, SIGTERM)
                let soft = Date().addingTimeInterval(0.2)
                var st: Int32 = 0
                while Date() < soft, waitpid(pid, &st, WNOHANG) == 0 { usleep(10_000) }
                kill(-pid, SIGKILL)
            }
            if !exited {
                var st: Int32 = 0
                while waitpid(pid, &st, 0) < 0 && errno == EINTR {}
                status = st
            }
        }
        running = 0
        if timedOut { return Result(output: out, status: 124) }
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Result(output: out, status: code)
    }

    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        ptrs.append(nil)
        defer { ptrs.forEach { free($0) } }
        return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

/// Our statusLine in Claude Code's user settings (`~/.claude/settings.json`). Changed only on the owner's switch: On
/// keeps the owner's statusLine (in the wrapper's folder) and puts ours in its place, with their padding and refresh
/// settings; Off puts theirs back, or removes ours when they had none. If the owner sets another statusLine later
/// (`/statusline`), ours is gone: the state is `replaced` and Settings asks them to switch it on again. Writes go
/// through `ClaudeSettingsHook.rewrite` (backup, re-read before the write, atomic, mode kept, links refused).
public enum ClaudeStatusLineSetting {
    public enum State: Sendable, Hashable { case off, on, replaced }

    /// The wrapper's command line: its path and the folder, quoted.
    public static func command(wrapper: String, dir: String) -> String {
        ClaudeQuestionHook.shellQuoted(wrapper) + " --dir " + ClaudeQuestionHook.shellQuoted(dir)
    }

    /// The statusLine's command is ours: this command, or the wrapper of a copy of the app that moved since.
    static func isOurs(_ line: Any?, command: String) -> Bool {
        guard let c = (line as? [String: Any])?["command"] as? String else { return false }
        return c == command || c.contains("/flockbook-statusline' --dir ")
    }

    /// `settings` with our statusLine, and the owner's to keep (nil: none, or ours was in already). A statusLine
    /// that is not an object is left alone.
    public static func enabling(_ settings: [String: Any], command: String) throws -> (settings: [String: Any], original: [String: Any]?) {
        let old = settings["statusLine"]
        if isOurs(old, command: command) { return (settings, nil) }
        let theirs: [String: Any]?
        switch old {
        case nil: theirs = nil
        case let o as [String: Any]: theirs = o
        default: throw ClaudeSettingsHook.Failure.unexpected("\"statusLine\" is not an object")
        }
        var line = theirs ?? [:]
        line["type"] = "command"
        line["command"] = command
        var s = settings
        s["statusLine"] = line
        return (s, theirs)
    }

    /// `settings` without ours: the owner's `original` back, or no statusLine. Another statusLine (the owner set it
    /// since) stays.
    public static func disabling(_ settings: [String: Any], command: String, original: [String: Any]?) -> [String: Any] {
        guard isOurs(settings["statusLine"], command: command) else { return settings }
        var s = settings
        s["statusLine"] = original
        return s
    }

    /// `wasOn`: the owner switched ours on and not off since.
    public static func state(_ settings: [String: Any], command: String, wasOn: Bool) -> State {
        if isOurs(settings["statusLine"], command: command) { return .on }
        return wasOn ? .replaced : .off
    }

    /// On or Off in the settings `file`, keeping the owner's statusLine in `folder`. Returns the backup (nil: nothing
    /// written). On while ours is in already changes nothing (the kept statusLine stays).
    @discardableResult
    public static func apply(on: Bool, file: URL, command: String, folder: StatusLineFolder, now: Date = Date(),
                             beforeWrite: (() -> Void)? = nil) throws -> URL? {
        if on {
            var kept: [String: Any]?, changed = false
            let before = folder.original(), wasOn = folder.wasOn
            do {
                let backup = try ClaudeSettingsHook.rewrite(file: file, now: now, beforeWrite: {
                    // The wrapper finds the owner's command from the moment ours is in.
                    folder.saveOriginal(kept, on: false)
                    beforeWrite?()
                }) { old in
                    if isOurs(old["statusLine"], command: command) { return nil }
                    let e = try enabling(old, command: command)
                    kept = e.original; changed = true
                    return e.settings
                }
                folder.saveOriginal(changed ? kept : before, on: true)
                return backup
            } catch {
                if changed { if wasOn { folder.saveOriginal(before, on: true) } else { folder.forgetOriginal() } }
                throw error
            }
        }
        let original = folder.original()
        let backup = try ClaudeSettingsHook.rewrite(file: file, now: now, beforeWrite: beforeWrite) { old in
            isOurs(old["statusLine"], command: command) ? disabling(old, command: command, original: original) : nil
        }
        folder.forgetOriginal()
        return backup
    }
}
