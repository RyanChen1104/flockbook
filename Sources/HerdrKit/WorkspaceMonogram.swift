import Foundation

/// The two letters of a workspace's monogram (the app's `Monogram`; the phone's `monogram()` in web/src/monogram.ts
/// does the same): the first letters of the first two words, or of a camelCase name's first two parts. A leading
/// "[TAG] " is left out. An apostrophe inside a word (Brandon's, O’Neil) does not split it.
public enum WorkspaceMonogram {
    public static func letters(_ raw: String) -> String {
        // "[ME] Meadow · Migration" -> ignore the leading [tag]
        var s = raw
        if s.hasPrefix("["), let e = s.firstIndex(of: "]") { s = String(s[s.index(after: e)...]).trimmingCharacters(in: .whitespaces) }
        if s.isEmpty { s = raw }
        s = withoutInnerApostrophes(s)
        var words = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.count == 1 {  // camelCase: OpenAtlas -> Open, Atlas
            var parts: [String] = [], cur = ""
            for ch in words[0] {
                if ch.isUppercase, !cur.isEmpty { parts.append(cur); cur = "" }
                cur.append(ch)
            }
            parts.append(cur); words = parts
        }
        if words.count >= 2 { return String(words[0].prefix(1) + words[1].prefix(1)).uppercased() }
        return String(s.prefix(2)).uppercased()
    }

    /// `s` without each ' or ’ that has a letter or digit on both sides.
    static func withoutInnerApostrophes(_ s: String) -> String {
        let chars = Array(s)
        func word(_ i: Int) -> Bool { chars.indices.contains(i) && (chars[i].isLetter || chars[i].isNumber) }
        return String(chars.indices.filter { !("'’".contains(chars[$0]) && word($0 - 1) && word($0 + 1)) }.map { chars[$0] })
    }
}
