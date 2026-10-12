import Foundation

/// How image files reach an agent: as a bracketed paste of the path. Claude Code turns a pasted image path into an
/// attachment (`[Image #1]`); the same path typed key by key stays plain text. Used by the composer and the remote hub.
public enum ImagePaste {
    public enum Segment: Hashable, Sendable {
        case text(String)
        /// An image file in the image folder, unquoted.
        case image(String)
    }

    /// Splits a composer message (text, then image paths, quoted as `ComposerHandle.quoted` does) into typed text and
    /// image paths. A path is pasted only when it names a PNG or JPEG directly in `directory`.
    public static func segments(_ message: String, directory: String) -> [Segment] {
        let dir = NSRegularExpression.escapedPattern(for: directory)
        let quotedDir = NSRegularExpression.escapedPattern(for: directory.replacingOccurrences(of: "'", with: "'\\''"))
        let name = "/([A-Za-z0-9][A-Za-z0-9._-]*\\.(?:png|jpe?g))"
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
        // Never paste a path with control characters (it could end the paste early).
        guard !directory.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) }) else { return [.text(message)] }
        return out
    }

    /// One path as a bracketed paste.
    public static func paste(_ path: String) -> String { "\u{1b}[200~" + path + "\u{1b}[201~" }
}
