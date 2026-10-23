import Foundation

/// Quoting for /bin/sh. One rule for every place that writes a path or command for a shell: between single quotes,
/// each ' inside becomes '\''. Done per Unicode scalar (the shell reads bytes): a ' followed by a combining mark
/// (U+0301) is one Character to Swift's String, and a Character match would leave that ' alone and end the quotes.
public enum ShellQuote {
    /// `s` between single quotes.
    public static func quoted(_ s: String) -> String { "'" + escapedInside(s) + "'" }

    /// What goes between the single quotes of `quoted(s)`.
    public static func escapedInside(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// `s` as it is when every scalar is plain (ASCII letters, digits and / . _ - + = : @ % ,), else `quoted(s)`.
    public static func quotedIfNeeded(_ s: String) -> String {
        if !s.isEmpty, s.unicodeScalars.allSatisfy(plain.contains) { return s }
        return quoted(s)
    }

    private static let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+=:@%,")
}
