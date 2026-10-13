import AppKit
import HerdrKit
import SwiftUI

/// Offscreen check of a live conversation under churn (`--test-conversation-churn`): items appended at the bottom, the
/// front trimmed and grown back (short/full log depth), the composer bar changing height, the window width changing, a
/// reader scrolled up while items arrive. After each change: is the viewport drawn (not blank)? After each scenario:
/// does the scroll view come to rest (no scroll or layout loop)? And how long did the main thread stall at most?
/// Synthetic items only. Under 60 s.
extension ContentTests {
    static func conversationChurn(_ args: [String]) async {
        // `--test-conversation-churn <rows>`: rows on screen (default 150, one page); a long session read far back has more.
        if let i = args.firstIndex(of: "--test-conversation-churn"), args.indices.contains(i + 1), let n = Int(args[i + 1]) { ConversationView.page = n }
        print("churn-test: \(ConversationView.page) rows shown of a 3000-item session")
        var failures = 0
        let t0 = Date()
        func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("churn-test: \(n) \(ok ? "ok" : "FAIL")") }
        let all = ChurnData.items(3000)
        let holder = ChurnHolder(items: Array(all.prefix(2800)))
        let size = NSSize(width: 1100, height: 760)
        let host = NSHostingView(rootView: ChurnView(holder: holder))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.contentView = host; win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1))

        // Main-thread stalls: a 5 ms timer; the longest gap between two ticks.
        let stall = StallMeter()
        stall.start()
        func scrollView() -> NSScrollView? {
            func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
            return views(host).compactMap { $0 as? NSScrollView }.max { $0.bounds.height < $1.bounds.height }
        }
        guard let sv = scrollView() else { step("scroll view found", false); exit(1) }
        // Scroll moves: the clip view's bounds origin. Counted to see whether the view comes to rest.
        var moves = 0
        sv.contentView.postsBoundsChangedNotifications = true
        let obs = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: .main) { _ in
            MainActor.assumeIsolated { moves += 1 }
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        /// Ink in the viewport between the bars: pixels away from their row's median tone, on a 3 px grid.
        func ink() -> Int {
            typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
                  let img = unsafeBitCast(sym, to: Fn.self)(.null, 8, UInt32(win.windowNumber), 1)?.takeRetainedValue(),
                  let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return -1 }
            let k = CGFloat(img.width) / win.frame.width, bpr = img.bytesPerRow, bpp = img.bitsPerPixel / 8
            let titleBar = win.frame.height - (win.contentView?.frame.height ?? win.frame.height)
            let y0 = Int((titleBar + holder.topBar + 30) * k), y1 = Int((win.frame.height - holder.bottomBar - 30) * k)
            guard y1 > y0 else { return -1 }
            var n = 0
            for y in stride(from: y0, to: y1, by: 3) {
                var row: [Int] = []
                for x in stride(from: Int(40 * k), to: img.width - Int(40 * k), by: 3) {
                    let o = y * bpr + x * bpp
                    row.append(Int(p[o]) + Int(p[o + 1]) + Int(p[o + 2]))
                }
                let mid = row.sorted()[row.count / 2]
                n += row.filter { abs($0 - mid) > 90 }.count
            }
            return n
        }
        func atBottom() -> Bool {
            let b = sv.contentView.bounds, doc = sv.documentView?.frame.height ?? 0
            return doc - b.maxY <= 40 + sv.contentInsets.bottom
        }
        var blanks: [String] = []
        var passes: [String: [Double]] = [:]
        /// One change, then two checks: right after one layout pass, and 300 ms later (at rest).
        func change(_ name: String, _ i: Int, _ f: () -> Void) async {
            f()
            let t = Date()
            host.layoutSubtreeIfNeeded()
            passes[name, default: []].append(Date().timeIntervalSince(t) * 1000)
            try? await Task.sleep(for: .milliseconds(250))
            let rest = ink()
            if rest >= 0, rest < 40 { blanks.append("\(name)#\(i) rest \(rest)") }
        }
        /// After a scenario: the view must come to rest within 1.5 s, then stay still for 2 s.
        func settle(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(1000))
            moves = 0
            let before = sv.contentView.bounds.origin.y
            try? await Task.sleep(for: .milliseconds(1500))
            step("\(name): comes to rest (\(moves) scroll moves in 1.5 s, y \(Int(before)) -> \(Int(sv.contentView.bounds.origin.y)))", moves == 0)
            let n = ink()
            step("\(name): viewport drawn at rest (\(n) ink)", n >= 40)
            if n < 40 { capture(win, to: "\(dir)/churn-\(ConversationView.page)-\(name)-blank.png") }
            let worst = stall.take() * 1000, p = (passes[name] ?? []).sorted()
            let p95 = p.isEmpty ? 0 : p[min(p.count - 1, p.count * 95 / 100)]
            print("churn-test: \(name): at \(Int(Date().timeIntervalSince(t0))) s; layout pass after a change: median \(Int(p.isEmpty ? 0 : p[p.count / 2])) ms, p95 \(Int(p95)) ms")
            step("\(name): longest main-thread stall \(Int(worst)) ms (under 250)", worst < 250)
        }

        // 1. Appends at the bottom (each new reply folds the one before it).
        var next = 2800
        for i in 0..<14 { await change("append", i) { holder.items.append(all[next]); next += 1 } }
        await settle("append")
        step("append: follows the bottom", atBottom())

        // 2. Front trimmed and grown back (log depth short <-> full), at the bottom.
        for i in 0..<8 {
            await change("depth", i) {
                if i % 2 == 0 { holder.items.removeFirst(60) } else { holder.items.insert(contentsOf: all[(next - holder.items.count - 60)..<(next - holder.items.count)], at: 0) }
            }
        }
        await settle("depth")

        // 3. Composer bar height changes (typing, an image, a question card), at the bottom.
        for i in 0..<10 { await change("composer", i) { holder.bottomBar = i % 2 == 0 ? 180 : 64 } }
        holder.bottomBar = 64
        await settle("composer")
        step("composer: still at the bottom", atBottom())

        // 4. Window width changes (sidebar, split, resize).
        for i in 0..<6 {
            await change("width", i) { win.setContentSize(NSSize(width: i % 2 == 0 ? 760 : 1100, height: size.height)) }
        }
        win.setContentSize(size)
        await settle("width")

        // 5. Reader scrolled up while items arrive and the front trims.
        let doc = sv.documentView?.frame.height ?? 0
        sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, doc / 2))); sv.reflectScrolledClipView(sv.contentView)
        try? await Task.sleep(for: .milliseconds(500))
        for i in 0..<12 {
            await change("scrolled-up", i) {
                if i % 5 == 4 { holder.items.removeFirst(20) } else { holder.items.append(all[next % all.count]); next += 1 }
            }
        }
        await settle("scrolled-up")
        step("scrolled-up: the reader stays up", !atBottom())

        // 6. Everything at once, fast: appends, composer, width, depth (a busy agent while typing).
        for i in 0..<24 {
            holder.items.append(all[next % all.count]); next += 1
            if i % 3 == 0 { holder.bottomBar = holder.bottomBar == 64 ? 120 : 64 }
            if i % 7 == 0 { holder.items.removeFirst(min(30, holder.items.count - 50)) }
            if i % 11 == 0 { win.setContentSize(NSSize(width: i % 2 == 0 ? 900 : 1100, height: size.height)) }
            try? await Task.sleep(for: .milliseconds(25))
        }
        holder.bottomBar = 64; win.setContentSize(size)
        await settle("burst")

        // 7. The row window: Show earlier past the cap drops the newest rows and offers Jump to latest, which goes back.
        // The lazy stack builds only rows near the viewport: the top for Show earlier, the bottom for Jump to latest.
        func scroll(top: Bool) async {
            let doc = sv.documentView?.frame.height ?? 0
            let y = top ? -sv.contentInsets.top : doc + sv.contentInsets.bottom - sv.contentView.bounds.height
            sv.contentView.scroll(to: NSPoint(x: 0, y: y)); sv.reflectScrolledClipView(sv.contentView)
            try? await Task.sleep(for: .milliseconds(500))
        }
        if ConversationView.page >= ConversationWindow.maxRows {
            await scroll(top: true); await scroll(top: true)   // twice: the first pass realizes rows and refines the height
            let earlier = ConversationProbe.earlier
            step("window: Show earlier on screen at the top (\(earlier))", earlier.height > 0 && earlier.minY >= 0)
            step("window: Show earlier is pressable", ConversationProbe.pressEarlier != nil)
            ConversationProbe.pressEarlier?()
            try? await Task.sleep(for: .milliseconds(600))
            await scroll(top: false); await scroll(top: false)
            let latest = ConversationProbe.latest
            step("window: Show earlier past \(ConversationWindow.maxRows) rows offers Jump to latest (\(latest))", latest.height > 0)
            let y = sv.contentView.bounds.origin.y
            holder.items.append(all[next % all.count]); next += 1
            try? await Task.sleep(for: .milliseconds(500))
            step("window: a new row leaves the older rows in place (y \(Int(y)) -> \(Int(sv.contentView.bounds.origin.y)))", abs(sv.contentView.bounds.origin.y - y) < 1)
            ConversationProbe.pressLatest?()
            try? await Task.sleep(for: .milliseconds(600))
            step("window: Jump to latest goes back to the newest rows, at the bottom (button \(ConversationProbe.latest))", ConversationProbe.latest == .zero && atBottom())
            let n = ink()
            step("window: viewport drawn after Jump to latest (\(n) ink)", n >= 40)
        }

        step("no blank viewport at rest after a change (\(blanks.count): \(blanks.prefix(6)))", blanks.isEmpty)
        stall.stop()
        win.orderOut(nil)
        print("churn-test: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        exit(failures == 0 ? 0 : 1)
    }
}

@MainActor @Observable private final class ChurnHolder {
    var items: [ConversationItem]
    var bottomBar: CGFloat = 64
    var topBar: CGFloat = 28
    init(items: [ConversationItem]) { self.items = items }
}

/// The pane's shape: ConversationView with a composer-like bar under it (PaneView uses safeAreaBar the same way).
private struct ChurnView: View {
    let holder: ChurnHolder
    var body: some View {
        ConversationView(items: holder.items, agentName: "churn", loadState: .ready)
            .safeAreaBar(edge: .top, spacing: 0) { Text("churn · label").font(.caption).frame(maxWidth: .infinity).frame(height: 28) }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                // The real composer (a text view that grows with its text), plus room for a taller bar.
                VStack(spacing: 0) {
                    ComposerView(agentName: "churn", draft: ComposerDraft(text: "A draft reply"), onSend: { _ in })
                    Color.clear.frame(height: max(0, holder.bottomBar - 64))
                }
            }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
    }
}

/// Longest gap between ticks of a 5 ms main-thread timer.
@MainActor private final class StallMeter {
    private var timer: Timer?
    private var last = Date()
    private var worst: TimeInterval = 0
    func start() {
        last = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date(); self.worst = max(self.worst, now.timeIntervalSince(self.last)); self.last = now
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func take() -> TimeInterval { defer { worst = 0 }; return worst }
    func stop() { timer?.invalidate() }
}

/// Synthetic conversation: user turns, replies of mixed length (paragraphs, lists, code), tool chips between.
enum ChurnData {
    static func items(_ n: Int) -> [ConversationItem] {
        var out: [ConversationItem] = []
        var t = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<n {
            t += 37
            switch i % 4 {
            case 0: out.append(ConversationItem(id: "u\(i)", kind: .userText("Step \(i): check the parser and report what changed."), timestamp: t))
            case 1, 2:
                let calls = (0..<(1 + i % 3)).map { ToolCall(id: "c\(i)-\($0)", toolName: "Read", summary: "Sources/File\($0).swift", input: "{}", output: "ok") }
                out.append(ConversationItem(id: "t\(i)", kind: .toolChips([ToolChip(symbol: "doc.text", text: "Read \(calls.count) files", calls: calls,
                                                                                     id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!)]), timestamp: t))
            default:
                let paras = 1 + (i * 7) % 9
                var s = "Finished step \(i). "
                for p in 0..<paras {
                    s += "\n\nParagraph \(p): the reader shows this text wrapped to the column width, with **bold** and `code` spans, long enough to take several lines in the reading column."
                    if p % 3 == 1 { s += "\n\n- first point\n- second point with more words\n- third" }
                    if p % 4 == 2 { s += "\n\n```swift\nlet value = parse(line)\nprint(value)\n```" }
                }
                out.append(ConversationItem(id: "a\(i)", kind: .assistantText(s), timestamp: t))
            }
        }
        return out
    }
}
