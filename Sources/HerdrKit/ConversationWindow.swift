import Foundation

/// Which rows of a conversation the reader shows: at most `maxRows`, ending at the newest row or, after "Show earlier"
/// went past `maxRows`, at an older row (`endId`). The stack is not lazy (a lazy stack's estimates left the viewport
/// blank and could re-measure without end): it lays out every row on a change, so the row count bounds that cost.
public struct ConversationWindow: Equatable, Sendable {
    public static let page = 100
    public static let maxRows = 150
    /// Rows in the window (fewer when the log has fewer).
    public var shown: Int
    /// The last row shown. nil: the newest row (the window follows new rows).
    public var endId: String?

    public init(shown: Int = ConversationWindow.page, endId: String? = nil) { self.shown = shown; self.endId = endId }

    /// The window ends before the newest row: new rows are not shown until "Jump to latest".
    public var detached: Bool { endId != nil }

    /// The indices of `ids` (oldest first) the window shows.
    public func range(_ ids: [String]) -> Range<Int> {
        let end = endId.flatMap { ids.lastIndex(of: $0) }.map { $0 + 1 } ?? ids.count   // an end row that left: the newest
        return max(0, end - shown)..<end
    }

    /// "Show earlier": `page` more rows before the window. Past `maxRows`, rows go from the newest end.
    public mutating func showEarlier(_ ids: [String], page: Int = ConversationWindow.page, maxRows: Int = ConversationWindow.maxRows) {
        let r = range(ids)
        let start = max(0, r.lowerBound - page), end = min(r.upperBound, start + maxRows)
        shown = max(end - start, page)
        endId = end < ids.count && end > 0 ? ids[end - 1] : nil
    }

    /// Back to the newest page.
    public mutating func jumpToLatest(page: Int = ConversationWindow.page) {
        let loads = loads
        self = ConversationWindow(shown: page)
        self.loads = loads   // a token of a read before the jump never matches a later read
    }

    /// The "Show earlier" read of the log in flight, if any: rows that then arrive in front join the window.
    public private(set) var pendingLoad: Int?
    private var loads = 0

    /// A read of older rows starts. Returns its token for `loadEnded`.
    public mutating func beginLoad() -> Int {
        loads += 1; pendingLoad = loads
        return loads
    }

    /// That read is over and nothing arrived (a timeout). An older read's end leaves a newer read pending.
    public mutating func loadEnded(_ token: Int) { if pendingLoad == token { pendingLoad = nil } }

    /// Rows arrived in front: when a read is pending, the window takes a page of them. True when it did.
    @discardableResult
    public mutating func takeLoaded(_ ids: [String], page: Int = ConversationWindow.page) -> Bool {
        guard pendingLoad != nil else { return false }
        pendingLoad = nil
        showEarlier(ids, page: page)
        return true
    }
}
