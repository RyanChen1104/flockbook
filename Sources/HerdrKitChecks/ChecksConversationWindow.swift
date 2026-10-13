import Foundation
@testable import HerdrKit

/// The reader's row window: one page at first, "Show earlier" grows it to at most 400 rows by dropping the newest ones,
/// "Jump to latest" goes back. The window holds its rows while new rows arrive or the front of the log is trimmed.
func checksConversationWindow() async throws {
    let ids = (0..<1000).map { "r\($0)" }
    var w = ConversationWindow()
    check(w.range(ids) == 900..<1000 && !w.detached, "window: the newest page at first (\(w.range(ids)))")
    check(ConversationWindow().range(Array(ids.prefix(30))) == 0..<30, "window: a short log shows all of it")
    w.showEarlier(ids); w.showEarlier(ids); w.showEarlier(ids)
    check(w.range(ids) == 600..<1000 && !w.detached, "window: Show earlier up to 400 rows keeps the newest (\(w.range(ids)))")
    w.showEarlier(ids)
    check(w.range(ids) == 500..<900 && w.detached && w.endId == "r899", "window: past 400 rows the newest go (\(w.range(ids)), end \(w.endId ?? "nil"))")
    let more = ids + (1000..<1010).map { "r\($0)" }
    check(w.range(more) == 500..<900, "window: a detached window holds its rows while new rows arrive (\(w.range(more)))")
    let trimmed = Array(ids.dropFirst(550))
    check(w.range(trimmed) == 0..<350, "window: the front trimmed under the window (\(w.range(trimmed)))")
    for _ in 0..<10 { w.showEarlier(ids) }
    check(w.range(ids) == 0..<400 && w.detached, "window: Show earlier stops at the first row (\(w.range(ids)))")
    w.jumpToLatest()
    check(w == ConversationWindow() && w.range(more) == 910..<1010, "window: Jump to latest shows the newest page again (\(w.range(more)))")
    var gone = ConversationWindow(shown: 400, endId: "missing")
    check(gone.range(ids) == 600..<1000, "window: an end row that left the log falls back to the newest (\(gone.range(ids)))")
    gone.showEarlier([])
    check(gone.range([]) == 0..<0, "window: an empty log")
    // Show earlier at the first row while the log loads older rows in front (onLoadEarlier): the window takes them.
    var front = ConversationWindow()
    let short = Array(ids.suffix(80))
    check(front.range(short) == 0..<80, "window: all of a short tail")
    front.showEarlier(ids)   // the store prepended 920 older rows
    check(front.range(ids) == 800..<1000 && !front.detached, "window: rows loaded in front join the window (\(front.range(ids)))")
}
