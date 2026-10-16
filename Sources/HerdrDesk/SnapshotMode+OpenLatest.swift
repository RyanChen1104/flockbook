import AppKit
import HerdrKit
import SwiftUI

/// Offscreen check (`--test-open-latest`): a conversation opens at its newest message and stays there, the way a pane
/// gets it. The log loads in steps: "loading", then a short tail, then the backfill in front. Also a switch to another
/// pane, the last reply growing, the window hidden and shown again. A reader who scrolled up is never pulled back.
/// Synthetic items only. Under 30 s.
extension ContentTests {
    static func openLatest() async {
        var failures = 0
        func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("open-latest: \(n) \(ok ? "ok" : "FAIL")") }
        let all = OpenLatestData.items(1200, seed: 0), other = OpenLatestData.items(600, seed: 1)
        let holder = OpenLatestHolder()
        let size = NSSize(width: 1000, height: 700)
        let host = NSHostingView(rootView: OpenLatestView(holder: holder))
        host.frame = NSRect(origin: .zero, size: size)
        let win = OffscreenWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.contentView = host; win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()

        func conversation() -> NSScrollView? {
            func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
            return views(host).compactMap { $0 as? NSScrollView }.max { $0.bounds.height < $1.bounds.height }
        }
        /// Distance from the newest message to the bottom of the view (0 = at the bottom). nil: no scroll view yet.
        func gap() -> CGFloat? {
            guard let s = conversation(), let d = s.documentView else { return nil }
            let visibleBottom = s.contentView.bounds.origin.y + s.contentView.bounds.height
            return d.isFlipped ? d.frame.height + s.contentInsets.bottom - visibleBottom : s.contentView.bounds.origin.y + s.contentInsets.bottom
        }
        func show(_ g: CGFloat?) -> String { g.map { String(format: "%.0f", $0) } ?? "-" }
        /// At the bottom right after a change and still there once it settled.
        func atBottom(_ name: String, soon: Double = 0.4, rest: Double = 1.5) async {
            try? await Task.sleep(for: .seconds(soon))
            let g1 = gap()
            try? await Task.sleep(for: .seconds(rest))
            let g2 = gap()
            step("\(name): at the newest message (gap \(show(g1)) pt after \(soon) s, \(show(g2)) pt at rest)", (g1 ?? 99) < 4 && (g2 ?? 99) < 4)
        }

        // 1. Open: loading, then the short tail (fewer rows than a page), then the backfill in front.
        holder.load = .loading; holder.items = []
        try? await Task.sleep(for: .milliseconds(400))
        holder.items = Array(all.suffix(40)); holder.load = .ready
        await atBottom("open: short tail", rest: 0.3)
        holder.items = Array(all.suffix(900))
        await atBottom("open: backfill in front")

        // 1b. The composer bar grows after the conversation opened (a card, a longer draft, the field settling): the
        // newest message moves up with it, never under it.
        holder.bar = 90
        await atBottom("composer grows")
        holder.bar = 0
        await atBottom("composer shrinks")

        // 2. Another pane: a new conversation view, its rows already loaded.
        holder.pane = "p2"; holder.items = Array(other.suffix(500))
        await atBottom("switch: rows at hand")
        // ... and a pane whose rows load after it opens.
        holder.pane = "p3"; holder.items = []; holder.load = .loading
        try? await Task.sleep(for: .milliseconds(300))
        holder.items = Array(all.suffix(300)); holder.load = .ready
        await atBottom("switch: rows load after")

        // 3. The last reply grows while it is written.
        for i in 0..<8 {
            var items = holder.items
            items[items.count - 1] = OpenLatestData.reply(id: items[items.count - 1].id, paragraphs: 2 + i * 2)
            holder.items = items
            try? await Task.sleep(for: .milliseconds(150))
        }
        await atBottom("streaming: the last reply grows")

        // 4. The window goes to the background and comes back with new rows.
        win.orderOut(nil)
        holder.items.append(contentsOf: OpenLatestData.items(6, seed: 2).map { ConversationItem(id: "bg-" + $0.id, kind: $0.kind, timestamp: $0.timestamp) })
        try? await Task.sleep(for: .milliseconds(500))
        win.orderFrontRegardless()
        await atBottom("background: back with new rows")

        // 4b. The window changes size the way full screen does (bigger, then back), with rows arriving in between.
        win.setContentSize(NSSize(width: 1512, height: 945)); win.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        holder.items.append(OpenLatestData.reply(id: "fs-0", paragraphs: 6))
        await atBottom("full-screen size: bigger")
        win.setContentSize(size); win.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        await atBottom("full-screen size: back")

        // 5. A reader who scrolled up stays where they are while rows arrive and the last reply grows.
        if let s = conversation(), let d = s.documentView {
            s.contentView.scroll(to: NSPoint(x: 0, y: max(0, d.frame.height / 2))); s.reflectScrolledClipView(s.contentView)
        }
        try? await Task.sleep(for: .milliseconds(500))
        let y0 = conversation()?.contentView.bounds.origin.y ?? 0
        for i in 0..<5 {
            holder.items.append(OpenLatestData.reply(id: "up-\(i)", paragraphs: 3))
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? await Task.sleep(for: .seconds(1))
        let y1 = conversation()?.contentView.bounds.origin.y ?? 0
        step("scrolled up: not pulled back (y \(Int(y0)) -> \(Int(y1)), gap \(show(gap())) pt)", abs(y1 - y0) < 2 && (gap() ?? 0) > 200)

        capture(win, to: "\(dir)/open-latest.png")
        win.orderOut(nil)
        print("open-latest: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        exit(failures == 0 ? 0 : 1)
    }
}

@MainActor @Observable private final class OpenLatestHolder {
    var pane = "p1"
    var items: [ConversationItem] = []
    var load: ConversationLoadState = .loading
    var bar: CGFloat = 0
}

/// The pane's shape (TabScreen): a fresh ConversationView per pane, label and composer bars over it.
private struct OpenLatestView: View {
    let holder: OpenLatestHolder
    var body: some View {
        ConversationView(items: holder.items, agentName: "open", agentStatus: .working, loadState: holder.load, hasLog: true,
                         onLoadEarlier: { false })
            .id(holder.pane)
            .safeAreaBar(edge: .top, spacing: 0) { Text("open · \(holder.pane)").font(.caption).frame(maxWidth: .infinity).frame(height: 28) }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: holder.bar)
                    ComposerView(agentName: "open", draft: ComposerDraft(text: ""), onSend: { _ in })
                }
            }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
    }
}

/// Synthetic conversation like a long agent session: user turns, tool chips, long replies (wrapped CJK and English
/// paragraphs, lists, code), the newest reply long.
enum OpenLatestData {
    static func reply(id: String, paragraphs: Int) -> ConversationItem {
        var s = "Done. "
        for p in 0..<paragraphs {
            s += p % 2 == 0
                ? "\n\n第 \(p) 段：這段文字很長，會在閱讀欄裡換成好幾行，裡面有 **粗體** 和 `code`，用來模擬 agent 回報進度時的長段落。"
                : "\n\nParagraph \(p): the reader wraps this text to the column width, long enough to take several lines in the reading column."
            if p % 3 == 1 { s += "\n\n1. first point\n2. second point with more words\n3. third" }
            if p % 4 == 2 { s += "\n\n```swift\nlet value = parse(line)\nprint(value)\n```" }
        }
        return ConversationItem(id: id, kind: .assistantText(s), timestamp: Date(timeIntervalSince1970: 1_800_000_000))
    }
    static func items(_ n: Int, seed: Int) -> [ConversationItem] {
        var out: [ConversationItem] = []
        var t = Date(timeIntervalSince1970: 1_800_000_000 + Double(seed) * 1_000_000)
        for i in 0..<n {
            t += 41
            let id = "s\(seed)-\(i)"
            switch i % 4 {
            case 0: out.append(ConversationItem(id: id, kind: .userText("Step \(i): 請檢查 parser，回報改了什麼。"), timestamp: t))
            case 1:
                let calls = (0..<(1 + i % 3)).map { ToolCall(id: "\(id)-\($0)", toolName: "Read", summary: "Sources/File\($0).swift", input: "{}", output: "ok") }
                out.append(ConversationItem(id: id, kind: .toolChips([ToolChip(symbol: "doc.text", text: "Read \(calls.count) files", calls: calls,
                                                                                  id: UUID(uuidString: String(format: "00000000-0000-0000-%04d-%012d", seed, i))!)]), timestamp: t))
            default:
                var r = reply(id: id, paragraphs: 1 + (i * 7) % 9); r.timestamp = t
                out.append(r)
            }
        }
        if n > 0 { out[out.count - 1] = reply(id: out[out.count - 1].id, paragraphs: 12) }   // the newest reply is long
        return out
    }
}
