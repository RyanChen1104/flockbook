import Foundation

/// Where a pane stands for scrolling. From `pane.get` (scroll) and `pane.process_info` (foreground program).
public struct ScrollInfo: Sendable, Equatable {
    public var maxOffsetFromBottom: Int
    public var offsetFromBottom: Int
    public var viewportRows: Int
    /// Name of the foreground program (`zsh`, `less`, `claude`). Nil when unknown.
    public var foregroundName: String?
    /// True when the shell itself is in the foreground. Nil when unknown.
    public var shellIsForeground: Bool?

    public enum Kind: Sendable, Equatable {
        /// herdr holds scrollback lines: show them (`readScrollback`), the wheel never goes to the program.
        case history
        /// No scrollback and a program other than the shell runs. Most likely a full-screen program (less, vim, htop) on
        /// the alternate screen. The program scrolls itself: the app may forward wheel events (as mouse or arrow bytes).
        case fullScreenProgram
        /// Nothing to scroll (fresh shell). Do not send anything.
        case none
    }
    public var kind: Kind {
        if maxOffsetFromBottom > 0 { return .history }
        return shellIsForeground == false ? .fullScreenProgram : .none
    }

    static func parse(pane: Data, process: Data?) throws -> ScrollInfo {
        guard let o = try JSONSerialization.jsonObject(with: pane) as? [String: Any],
              let r = o["result"] as? [String: Any], let p = r["pane"] as? [String: Any],
              let sc = p["scroll"] as? [String: Any] else { throw HerdrError.protocolError("pane.get has no scroll info") }
        var info = ScrollInfo(maxOffsetFromBottom: sc["max_offset_from_bottom"] as? Int ?? 0,
                              offsetFromBottom: sc["offset_from_bottom"] as? Int ?? 0,
                              viewportRows: sc["viewport_rows"] as? Int ?? 0)
        if let process,
           let po = try? JSONSerialization.jsonObject(with: process) as? [String: Any],
           let pi = (po["result"] as? [String: Any])?["process_info"] as? [String: Any] {
            let fg = pi["foreground_processes"] as? [[String: Any]] ?? []
            info.foregroundName = fg.first?["name"] as? String
            if let shell = pi["shell_pid"] as? Int {
                info.shellIsForeground = fg.isEmpty ? nil : fg.contains { $0["pid"] as? Int == shell }
            }
        }
        return info
    }
}

/// Terminal history as text. `ansi` text keeps SGR colors and uses CRLF line ends, so it can go straight into a terminal view.
public struct Scrollback: Sendable {
    /// Most lines one `pane.read` returns (herdr 0.9.1).
    public static let readLimit = 1000
    public var text: String
    /// herdr cut the history (it holds more than was returned).
    public var truncated: Bool
    public var revision: Int
    public var lineCount: Int

    static func parse(_ data: Data) throws -> Scrollback {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = (o["result"] as? [String: Any])?["read"] as? [String: Any],
              let text = r["text"] as? String else { throw HerdrError.protocolError("pane.read has no text") }
        var n = text.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        if let last = text.utf8.last, last != 0x0A { n += 1 }
        return Scrollback(text: text, truncated: r["truncated"] as? Bool ?? false, revision: r["revision"] as? Int ?? 0, lineCount: n)
    }
}

extension HerdrClient {
    /// Scroll state of a pane. Two read-only requests.
    public func scrollInfo(paneId: String) async throws -> ScrollInfo {
        let pane = try await rawRequest(method: "pane.get", params: ["pane_id": paneId])
        let proc = try? await rawRequest(method: "pane.process_info", params: ["pane_id": paneId])
        return try ScrollInfo.parse(pane: pane, process: proc)
    }

    /// The pane's history and screen: the last `lines` lines of the terminal buffer (main screen scrollback plus the visible
    /// rows). herdr returns at most `Scrollback.readLimit` (1000) lines here; `truncated` is true when more exist (see
    /// `readDeepHistory`). Read-only: it sends no input and does not move the pane's own scroll position, so it is the way to scroll
    /// an observe-only view. In a full-screen program (alternate screen) herdr only has that screen.
    /// `unwrapped` joins soft-wrapped lines, so a local view can reflow to its own width.
    public func readScrollback(paneId: String, lines: Int = 5000, ansi: Bool = true, unwrapped: Bool = false) async throws -> Scrollback {
        try Scrollback.parse(try await rawRequest(method: "pane.read", params: [
            "pane_id": paneId, "source": unwrapped ? "recent_unwrapped" : "recent", "lines": max(1, lines),
            "format": ansi ? "ansi" : "text", "strip_ansi": !ansi,
        ]))
    }

    /// Moves the pane's scroll position (0 = bottom). **Shared state:** every client of that pane (the herdr TUI, other
    /// observers) sees the pane scrolled, and it stays so until set back to 0. Sends no input. Prefer `readScrollback`
    /// for a private view; use this only when the herdr-rendered frame itself must scroll.
    public func setScrollOffset(paneId: String, fromBottom: Int) async throws {
        _ = try await rawRequest(method: "pane.scroll", params: ["pane_id": paneId, "offset_from_bottom": max(0, fromBottom)])
    }
}

extension HerdrClient {
    /// History deeper than `Scrollback.readLimit`: moves the pane's scroll position one screen at a time and reads each
    /// screen, then puts the position back. **Not read-only for a moment:** while it runs, other clients of the pane (the herdr
    /// TUI) see the pane scroll. Use it when the user asks for older lines than `readScrollback` returned (`truncated`).
    /// Returns up to `lines` lines ending at the current screen. In a full-screen program it returns the screen only.
    public func readDeepHistory(paneId: String, lines: Int = 10_000, ansi: Bool = true) async throws -> Scrollback {
        // Output arriving during the read shifts every page (offsets count from the bottom). The buffer size is checked
        // after each pass; a pass that saw growth is repeated (up to 3 times, then the last pass is returned).
        var result: Scrollback?
        for _ in 0..<3 {
            let before = try await scrollInfo(paneId: paneId)
            let r = try await deepPass(paneId: paneId, lines: lines, ansi: ansi, info: before)
            result = r
            let after = try await scrollInfo(paneId: paneId)
            if after.maxOffsetFromBottom == before.maxOffsetFromBottom { break }
        }
        return result!
    }

    private func deepPass(paneId: String, lines: Int, ansi: Bool, info: ScrollInfo) async throws -> Scrollback {
        let rows = max(1, info.viewportRows)
        let wantTop = min(info.maxOffsetFromBottom, max(0, lines - rows))     // offset of the oldest screen to read
        var out: [String] = []
        var offset = wantTop
        var revision = 0
        var previous: Int?
        do {
          while true {
            try await setScrollOffset(paneId: paneId, fromBottom: offset)
            let page = try Scrollback.parse(try await rawRequest(method: "pane.read", params: [
                "pane_id": paneId, "source": "visible", "format": ansi ? "ansi" : "text", "strip_ansi": !ansi,
            ]))
            revision = page.revision
            var ls = page.text.components(separatedBy: "\n")
            if ls.last == "" { ls.removeLast() }
            if let prev = previous { ls = Array(ls.dropFirst(rows + offset - prev)) }   // the last step can overlap
            out.append(contentsOf: ls)
            previous = offset
            if offset == 0 { break }
            offset = max(0, offset - rows)
          }
        } catch {
            try? await setScrollOffset(paneId: paneId, fromBottom: info.offsetFromBottom)
            throw error
        }
        try await setScrollOffset(paneId: paneId, fromBottom: info.offsetFromBottom)
        return Scrollback(text: out.joined(separator: "\n"), truncated: info.maxOffsetFromBottom > wantTop,
                          revision: revision, lineCount: out.count)
    }
}
