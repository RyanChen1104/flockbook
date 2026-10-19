import Foundation

/// Pictures stored in session logs (base64 in the JSON). Items keep only a `Ref`; the bytes are read back from the log on demand.
public enum LogImage {
    public enum Format: String, Sendable, Hashable { case png, jpeg, webp, gif }

    /// Where a picture is: the nth picture (`index`, log order) of the line at byte `offset`. Size from the file header.
    public struct Ref: Sendable, Hashable {
        public var format: Format
        public var width: Int, height: Int
        public var offset: UInt64?
        public var index: Int
        public init(format: Format, width: Int, height: Int, offset: UInt64?, index: Int) {
            self.format = format; self.width = width; self.height = height; self.offset = offset; self.index = index
        }
    }

    public static func header(_ d: Data) -> (format: Format, width: Int, height: Int)? { nil }
    public static func header(base64: String) -> (format: Format, width: Int, height: Int)? { nil }
    public static func data(line: String, index: Int) -> Data? { nil }
    public static func read(_ ref: Ref, from url: URL) -> Data? { nil }
}
