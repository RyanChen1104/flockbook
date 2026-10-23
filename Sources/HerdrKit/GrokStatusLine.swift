import Foundation

public enum GrokStatusLineSetting {
    public enum State: Sendable, Hashable { case off, on, replaced, moved }
    public static func enabling(_ text: String, command: String) throws -> (text: String, original: [String: Any]?) { (text, nil) }
    public static func disabling(_ text: String, command: String, original: [String: Any]?) throws -> String? { nil }
    public static func state(_ text: String, command: String, wasOn: Bool) -> State { .off }
    public static func currentCommand(_ text: String) -> String? { nil }
    @discardableResult
    public static func apply(on: Bool, file: URL, command: String, folder: StatusLineFolder, now: Date = Date(),
                             beforeWrite: (() -> Void)? = nil) throws -> URL? { nil }
}

public enum GrokBuiltinLine {
    public static func render(_ input: Data, items: [String], now: Date) -> String { "" }
}
