import Foundation

/// How image files reach an agent: as a bracketed paste of the path. Claude Code turns a pasted image path into an
/// attachment (`[Image #1]`); the same path typed key by key stays plain text. Used by the composer and the remote hub.
public enum ImagePaste {
    public enum Segment: Hashable, Sendable {
        case text(String)
        /// An image file in the image folder, unquoted.
        case image(String)
    }

    private static let uuid = "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
    /// The names the app gives: the hub's `remote-<UUID>.png|jpg`, the composer's `<UUID>.png`.
    private static let ownName = "(?:remote-\(uuid)\\.(?:png|jpg)|\(uuid)\\.png)"

    /// Splits a composer message (text, then image paths, quoted as `ComposerHandle.quoted` does) into typed text and
    /// image paths. Lexical only: a path counts when it names a file of ours (`isOwnName`) directly in `directory`.
    public static func segments(_ message: String, directory: String) -> [Segment] {
        // Never paste a path with control characters (it could end the paste early).
        guard !directory.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) }) else { return [.text(message)] }
        let dir = NSRegularExpression.escapedPattern(for: directory)
        let quotedDir = NSRegularExpression.escapedPattern(for: ShellQuote.escapedInside(directory))
        let name = "/(\(ownName))"
        guard let re = try? NSRegularExpression(pattern: "'\(quotedDir)\(name)'|(?<![^\\s])\(dir)\(name)(?![^\\s])") else { return [.text(message)] }
        let ns = message as NSString
        var out: [Segment] = []
        var at = 0
        for m in re.matches(in: message, range: NSRange(location: 0, length: ns.length)) {
            let file = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ns.substring(with: m.range(at: 2))
            if m.range.location > at { out.append(.text(ns.substring(with: NSRange(location: at, length: m.range.location - at)))) }
            out.append(.image(directory + "/" + file))
            at = m.range.location + m.range.length
        }
        if at < ns.length { out.append(.text(ns.substring(from: at))) }
        return out
    }

    /// One send step: `input` = text through the composer's normal text call (no keys); `paste` = a path as a
    /// bracketed paste. Raw text never goes through the paste call, so LF and tab keep their usual meaning.
    public enum Step: Hashable, Sendable { case input(String), paste(String) }

    /// The steps for a message: a path is pasted only when it is one of our files that exists now (`isFile`);
    /// anything else is text. Adjacent text is one step.
    public static func plan(_ message: String, directory: String, isFile: (String) -> Bool = ownFile) -> [Step] {
        var out: [Step] = []
        func text(_ t: String) {
            if case .input(let prev)? = out.last { out[out.count - 1] = .input(prev + t) } else if !t.isEmpty { out.append(.input(t)) }
        }
        for seg in segments(message, directory: directory) {
            switch seg {
            case .text(let t): text(t)
            case .image(let path):
                if isFile(path) { out.append(.paste(path)) } else { text(message.contains("'\(path)'") ? "'\(path)'" : path) }
            }
        }
        return out
    }

    /// A file name the app makes: `remote-<UUID>.png|jpg` (hub) or `<UUID>.png` (composer paste), UUID in capitals.
    public static func isOwnName(_ name: String) -> Bool {
        name.range(of: "^\(ownName)$", options: .regularExpression) != nil
    }

    /// An existing regular file (not a link) owned by this user.
    public static func ownFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG && st.st_uid == getuid()
    }

    /// Agents that turn a pasted image path into `[Image #n]` (seen live: Claude Code, Codex, Grok Build; pi keeps
    /// the path).
    public static func waitsForMarker(kind: String) -> Bool { kind == "claude" || kind == "codex" || kind == "grok" }

    /// `[Image #` markers in the agent's input: after its last prompt line (Claude `❯`, Codex `›`, Grok `│ ❯` in its
    /// input box), or the whole screen without one. Markers in the history above do not count. A long input wraps and
    /// can break a marker ("[Image" / "  #2]"): the lines are joined without their indent and box edges first.
    public static func inputMarkers(_ screen: String, kind: String) -> Int {
        let glyph: Character = kind == "codex" ? "›" : "❯"
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false)
        let start = lines.lastIndex { l in
            let t = l.drop { $0 == " " }
            guard kind == "grok" else { return t.first == glyph }
            return t.first == "│" && t.dropFirst().drop { $0 == " " }.first == glyph
        } ?? lines.startIndex
        let edge: (Character) -> Bool = { $0 == " " || $0 == "│" }
        let input = lines[start...].map { l in
            var t = Substring(l).drop(while: edge)
            while let c = t.last, edge(c) { t = t.dropLast() }
            return t
        }.joined()
        return input.components(separatedBy: "[Image").dropFirst().filter { $0.drop { $0 == " " }.first == "#" }.count
    }

    /// One path as a bracketed paste.
    public static func paste(_ path: String) -> String { "\u{1b}[200~" + path + "\u{1b}[201~" }
}
