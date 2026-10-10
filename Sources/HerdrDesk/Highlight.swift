import SwiftUI
import AppKit

/// Small token-based highlighter for code blocks (reading.md §7). Unknown language -> plain text.
/// Colors are the Xcode-like set from the spec, all >= 4.5:1 on the code fill.
enum Highlight {
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let h = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1)
        })
    }
    static let keyword = dyn(0xA0329A, 0xFC5FA3)
    static let string = dyn(0xC41A16, 0xFC6A5D)
    static let number = dyn(0x1C00CF, 0xD9C97C)
    static let type = dyn(0x0B4F79, 0x5DD8FF)
    static let function = dyn(0x326D74, 0x67B7A4)
    static let comment = dyn(0x5F6873, 0x8B96A1)

    private static let swift: Set<String> = ["let", "var", "func", "if", "else", "for", "in", "while", "return", "guard", "switch", "case", "default", "struct", "class", "enum", "protocol", "extension", "import", "init", "self", "super", "nil", "true", "false", "try", "catch", "throw", "throws", "async", "await", "private", "public", "internal", "static", "final", "some", "any", "where", "do", "break", "continue", "defer", "typealias", "actor", "override", "weak", "inout"]
    private static let js: Set<String> = ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "class", "extends", "new", "this", "import", "from", "export", "async", "await", "try", "catch", "throw", "typeof", "instanceof", "null", "undefined", "true", "false", "interface", "type", "enum", "implements", "of", "in", "yield", "static", "public", "private"]
    private static let py: Set<String> = ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "with", "try", "except", "finally", "raise", "lambda", "pass", "break", "continue", "in", "is", "not", "and", "or", "None", "True", "False", "async", "await", "yield", "global", "self"]
    private static let rust: Set<String> = ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "match", "if", "else", "for", "while", "loop", "return", "self", "Self", "const", "static", "async", "await", "move", "ref", "as", "in", "where", "type", "true", "false", "break", "continue", "unsafe", "dyn"]
    private static let go: Set<String> = ["func", "var", "const", "type", "struct", "interface", "package", "import", "if", "else", "for", "range", "return", "switch", "case", "default", "go", "defer", "chan", "map", "select", "break", "continue", "nil", "true", "false"]
    private static let sh: Set<String> = ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "in", "return", "export", "local", "echo", "cd", "set", "unset", "source"]

    private struct Lang { let keywords: Set<String>; let line: [String]; let block: (String, String)?; let types: Bool }

    private static func lang(_ hint: String?) -> Lang? {
        switch (hint ?? "").lowercased() {
        case "swift": Lang(keywords: swift, line: ["//"], block: ("/*", "*/"), types: true)
        case "js", "javascript", "ts", "typescript", "jsx", "tsx": Lang(keywords: js, line: ["//"], block: ("/*", "*/"), types: true)
        case "py", "python": Lang(keywords: py, line: ["#"], block: nil, types: true)
        case "rust", "rs": Lang(keywords: rust, line: ["//"], block: ("/*", "*/"), types: true)
        case "go", "golang": Lang(keywords: go, line: ["//"], block: ("/*", "*/"), types: true)
        case "sh", "bash", "zsh", "shell", "console": Lang(keywords: sh, line: ["#"], block: nil, types: false)
        case "json", "jsonc": Lang(keywords: ["true", "false", "null"], line: [], block: nil, types: false)
        case "yaml", "yml": Lang(keywords: ["true", "false", "null"], line: ["#"], block: nil, types: false)
        default: nil
        }
    }

    static func attributed(_ text: String, lang hint: String?) -> AttributedString {
        var out = AttributedString(text)
        guard text.count < 20_000, let L = lang(hint) else { return out }
        let chars = Array(text)
        // Map from character offset to AttributedString index, built once.
        var idx: [AttributedString.Index] = []
        idx.reserveCapacity(chars.count + 1)
        var i = out.startIndex
        for _ in 0..<chars.count { idx.append(i); i = out.index(afterCharacter: i) }
        idx.append(out.endIndex)
        func paint(_ a: Int, _ b: Int, _ c: Color) { if a < b { out[idx[a]..<idx[b]].foregroundColor = c } }
        func starts(_ s: String, at p: Int) -> Bool {
            let u = Array(s); guard p + u.count <= chars.count else { return false }
            for k in 0..<u.count where chars[p + k] != u[k] { return false }
            return true
        }
        var p = 0
        while p < chars.count {
            let c = chars[p]
            if let l = L.line.first(where: { starts($0, at: p) }) {
                _ = l; var e = p; while e < chars.count, chars[e] != "\n" { e += 1 }
                paint(p, e, comment); p = e; continue
            }
            if let b = L.block, starts(b.0, at: p) {
                var e = p + b.0.count; while e < chars.count, !starts(b.1, at: e) { e += 1 }
                e = min(chars.count, e + b.1.count); paint(p, e, comment); p = e; continue
            }
            if c == "\"" || c == "'" || c == "`" {
                var e = p + 1
                while e < chars.count, chars[e] != c, chars[e] != "\n" || c == "`" { if chars[e] == "\\" { e += 1 }; e += 1 }
                e = min(chars.count, e + 1); paint(p, e, string); p = e; continue
            }
            if c.isNumber, p == 0 || !(chars[p - 1].isLetter || chars[p - 1] == "_") {
                var e = p; while e < chars.count, chars[e].isNumber || chars[e] == "." || chars[e] == "_" || chars[e].isHexDigit || chars[e] == "x" { e += 1 }
                paint(p, e, number); p = e; continue
            }
            if c.isLetter || c == "_" {
                var e = p; while e < chars.count, chars[e].isLetter || chars[e].isNumber || chars[e] == "_" { e += 1 }
                let word = String(chars[p..<e])
                if L.keywords.contains(word) { paint(p, e, keyword) }
                else if L.types, c.isUppercase { paint(p, e, type) }
                else if e < chars.count, chars[e] == "(" { paint(p, e, function) }
                p = e; continue
            }
            p += 1
        }
        return out
    }
}

/// Fades the trailing edge so the reader sees there is more to scroll to.
extension View {
    func trailingFade(_ on: Bool, width: CGFloat = 24) -> some View {
        mask {
            if on {
                HStack(spacing: 0) { Color.black; LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: width) }
            } else { Color.black }
        }
    }
}
