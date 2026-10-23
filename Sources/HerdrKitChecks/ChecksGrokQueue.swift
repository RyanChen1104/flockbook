import Foundation
@testable import HerdrKit

// Grok Build's queue and image paste. Its log has a queued message only once it goes in, so the queue comes from the
// screen: "#N text" rows above the spinner, one row each (a long one cut with "…"), while the footer offers
// "Ctrl+;:queue". A pasted image path becomes "[Image #N]" in its input box ("│ ❯ …").
@MainActor func checksGrokQueue() async throws {
    let working = Agent(name: "grok", kind: "grok", status: .working, sessionId: "g1", title: "")
    // The screen as Grok Build 1.0.67 draws it while it works (shape captured live; text synthetic).
    func screen(_ queued: [String], input: String = "", footer: String? = nil) -> String {
        var l = ["  ❯ Write a story.", "", "     Once upon a time.", ""]
        for (i, q) in queued.enumerated() { l.append("    #\(i + 1) \(q)") }
        l += ["", "    ⠼ Thinking… 3.2s                                       5.6s ⇣1.46k [stop]", "",
              "  ╭──────────────────────────────────────────╮", "  │ ❯ \(input)  │", "  ╰──────────────────────── Grok 4.7 (high) ─╯", "",
              footer ?? (queued.isEmpty ? "  Shift+Tab:mode  │  Ctrl+c:cancel  │  Ctrl+.:shortcuts"
                                        : "  Enter:send now  │  Shift+Tab:mode  │  Ctrl+c:cancel  │  Ctrl+;:queue  │  Ctrl+.:shortcuts")]
        return l.joined(separator: "\n")
    }
    let two = screen(["Reply with alpha.", "Reply with beta, and this one is long enough to be cut on…"])
    check(QueuedInput.grokScreen(two) == ["Reply with alpha.", "Reply with beta, and this one is long enough to be cut on…"],
          "grok queue: the #N rows, oldest first \(String(describing: QueuedInput.grokScreen(two)))")
    let q = QueuedInput.read(agent: working, screen: two, log: [])
    check(q?.agent == "grok" && q?.items.count == 2 && q?.pullable == false && q?.pullsAll == false, "grok queue: read, never pulled back \(String(describing: q))")
    check(QueuedInput.grokScreen(screen([])) == nil && QueuedInput.read(agent: working, screen: screen([]), log: []) == nil, "grok queue: none queued")
    check(QueuedInput.grokScreen(screen(["Reply with alpha."], footer: "  Shift+Tab:mode  │  Ctrl+.:shortcuts")) == nil, "grok queue: no Ctrl+;:queue in the footer, no queue")
    var idle = working; idle.status = .idle
    check(QueuedInput.read(agent: idle, screen: two, log: []) == nil, "grok queue: none unless grok works")
    // The answer's own "#1" lines are not the queue: only the rows right above the spinner, numbered from 1.
    let answer = screen(["Reply with alpha."]).replacingOccurrences(of: "     Once upon a time.", with: "    #1 Step one\n    #2 Step two\n\n     Done.")
    check(QueuedInput.grokScreen(answer) == ["Reply with alpha."], "grok queue: numbered lines in the answer do not count \(String(describing: QueuedInput.grokScreen(answer)))")
    check(QueuedInput.grokScreen(screen(["A"]).replacingOccurrences(of: "#1 A", with: "#2 A")) == nil, "grok queue: rows not numbered from 1: none")
    check(QueuedInput.reads(kind: "grok") && QueuedInput.reads(kind: "claude") && QueuedInput.reads(kind: "codex") && !QueuedInput.reads(kind: "pi"),
          "grok queue: the agents whose queue Flockbook reads")
    check(QueuePull.pullKey(agent: "grok") == nil, "grok queue: no pull key")
    check(QueuedInput.editHint(agent: "grok")?.contains("Ctrl+;") == true && QueuedInput.editHint(agent: "codex")?.contains("Shift+Left") == true
          && QueuedInput.editHint(agent: "claude") == nil, "grok queue: where to change it in the terminal")

    // A pull is refused before any key, with where to change it.
    final class IO: QueuePull.IO, @unchecked Sendable {
        var keys: [[String]] = []
        let s: String, a: Agent
        init(_ s: String, _ a: Agent) { self.s = s; self.a = a }
        func agent() async -> Agent? { a }
        func screen() async -> String? { s }
        func keys(_ k: [String], expect: Agent) async -> Bool { keys.append(k); return true }
        func settle() async {}
        func width() async -> Int? { 120 }
    }
    let io = IO(two, working)
    let r = await QueuePull.run(expect: working, log: [], io: io)
    if case .refused(let why) = r { check(why.contains("Grok") && io.keys.isEmpty, "grok queue: pull refused, nothing sent (\(why))") }
    else { check(false, "grok queue: pull refused \(r)") }

    // Image paste: Grok shows "[Image #N]" in its box; markers in the history above (its "❯ " prompt lines) do not count.
    check(ImagePaste.waitsForMarker(kind: "grok"), "grok image: waits for [Image #n]")
    let old = "  ❯ look [Image #1]\n\n     A red square.\n\n  ╭────────╮\n  │ ❯      │\n  ╰────────╯\n  Shift+Tab:mode"
    let new = "  ❯ look [Image #1]\n\n     A red square.\n\n  ╭────────╮\n  │ ❯ [Image #2] and   │\n  │   [Image #3] these │\n  ╰────────╯\n  Shift+Tab:mode"
    check(ImagePaste.inputMarkers(old, kind: "grok") == 0 && ImagePaste.inputMarkers(new, kind: "grok") == 2,
          "grok image: markers in its input box only (\(ImagePaste.inputMarkers(old, kind: "grok")), \(ImagePaste.inputMarkers(new, kind: "grok")))")
}
