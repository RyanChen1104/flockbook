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
        // The probe actions: none outside the checks, and none after the view left.
        let probe = ProbeHolder()
        let probeWin = OffscreenWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        probeWin.contentView = NSHostingView(rootView: ProbeView(holder: probe)); probeWin.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        probeWin.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(500))
        step("probe: no action kept outside the checks", ConversationProbe.pressEarlier == nil)
        ConversationProbe.enabled = true
        probe.generation += 1
        try? await Task.sleep(for: .milliseconds(500))
        step("probe: a check gets the Show earlier action", ConversationProbe.pressEarlier != nil)
        probe.shown = false
        try? await Task.sleep(for: .milliseconds(500))
        step("probe: the action goes with the view", ConversationProbe.pressEarlier == nil)
        probeWin.orderOut(nil)

        let all = ChurnData.items(3000)
        let holder = ChurnHolder(items: Array(all.prefix(2800)))
        let size = NSSize(width: 1100, height: 760)
        let opened = Date()
        let host = NSHostingView(rootView: ChurnView(holder: holder))
        host.frame = NSRect(origin: .zero, size: size)
        let win = OffscreenWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.contentView = host; win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()
        host.layoutSubtreeIfNeeded(); win.displayIfNeeded()
        print("churn-test: first view: laid out and drawn in \(Int(Date().timeIntervalSince(opened) * 1000)) ms (\(ConversationView.page) rows)")
        try? await Task.sleep(for: .seconds(1))

        // Selectable text: SwiftUI puts an AppKit overlay on each selectable Text and re-sets its font on every update,
        // which asks for another layout: with every row selectable a window could lay out forever. The conversation has
        // no SwiftUI selectable text: each message is one text view.
        func overlays(_ v: NSView) -> Int {
            (String(describing: type(of: v)).contains("SelectionTextField") ? 1 : 0) + v.subviews.reduce(0) { $0 + overlays($1) }
        }
        let n = overlays(host)
        step("selectable text: \(n) SwiftUI selection overlays in the conversation (want 0)", n == 0)
        // One message is one text view: selecting all of it takes every paragraph, list and code block.
        let multi = Self.all(NSTextView.self, in: host).first { !$0.isEditable && $0.string.hasPrefix("Finished step") && $0.string.contains("Paragraph 2:") }
        if let tv = multi {
            tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
            let pb = NSPasteboard(name: NSPasteboard.Name("churn-test-\(UUID().uuidString)"))
            pb.clearContents()
            // The types Cmd-C and the menu's Copy write: plain text only, so a rich paste cannot bring back code labels or
            // raw list markers.
            _ = tv.writeSelection(to: pb, types: tv.writablePasteboardTypes)
            let copied = pb.string(forType: .string) ?? ""
            let types = pb.types ?? []
            pb.releaseGlobally()
            step("copy: plain text only (\(types.map(\.rawValue)))", !types.isEmpty && Set(types).isSubset(of: [.string, NSPasteboard.PasteboardType("NSStringPboardType")]))
            let last = tv.string.components(separatedBy: "\n").last { $0.hasPrefix("Paragraph ") }.map { String($0.prefix(13)) } ?? "?"
            step("selection: one message is one text view; all of it copies the first and the last paragraph (\(last))",
                 copied.hasPrefix("Finished step") && copied.contains(last) && copied.contains("let value = parse(line)"))
        } else { step("selection: a multi-paragraph message is one selectable text view", false) }
        // Older long replies fold to 14 lines: the text view is cut there.
        let line = (ReadingSize(rawValue: AppDefaults.store.string(forKey: ReadingSize.key) ?? "") ?? .m).line
        let folded = Self.all(MessageTextView.self, in: host).filter { $0.fold != nil }
        step("fold: \(folded.count) folded replies, each \(Int(line * 14)) pt tall (\(folded.map { Int($0.frame.height) }.prefix(4)))",
             !folded.isEmpty && folded.allSatisfy { abs($0.frame.height - line * 14) < 1 })

        // Main-thread stalls: a 5 ms timer; the longest gap between two ticks, not counting the check's own captures.
        let stall = StallMeter()
        stall.start()
        func scrollView() -> NSScrollView? {
            func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
            return views(host).compactMap { $0 as? NSScrollView }.max { $0.bounds.height < $1.bounds.height }
        }
        guard let sv = scrollView() else { step("scroll view found", false); exit(1) }
        // A text view never scrolls the conversation itself. When SwiftUI resizes a text view, NSTextView's setFrameSize
        // asks the enclosing scroll view to show a rect of it (scrollToVisible). SwiftUI does not see that scroll: a lazy
        // stack can keep the rows of the old range and leave the viewport blank until the next change.
        let clip = sv.contentView.bounds
        if let tv = Self.all(MessageTextView.self, in: host).last, clip.minY > 2000 {
            // A rect well above the viewport, in the text view's coordinates.
            let asked = tv.scrollToVisible(tv.convert(NSRect(x: 0, y: clip.minY - 2000, width: 10, height: 10), from: sv.contentView))
            let moved = sv.contentView.bounds.origin.y - clip.origin.y
            if abs(moved) > 0.5 { sv.contentView.scroll(to: clip.origin); sv.reflectScrolledClipView(sv.contentView) }
            step("text view: does not scroll the conversation (moved \(Int(moved)) pt, scrolled \(asked))", abs(moved) < 0.5 && !asked)
        } else { step("text view: one in the conversation, scrolled down", false) }
        // Scroll moves: the clip view's bounds origin. Counted to see whether the view comes to rest.
        var moves = 0
        sv.contentView.postsBoundsChangedNotifications = true
        let obs = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: .main) { _ in
            MainActor.assumeIsolated { moves += 1 }
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        /// Ink in the viewport between the bars: pixels away from their row's median tone, on a 3 px grid.
        func ink() -> Int {
            stall.pause(); defer { stall.resume() }   // the check's own work (capture, pixel scan) is not an app stall
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
        // The meter: a stall just before a capture counts; the capture itself does not.
        try? await Task.sleep(for: .milliseconds(100))
        _ = stall.take()
        usleep(300_000)   // an app stall, then a capture before the timer ticks again
        _ = ink()
        let before = stall.take()
        step("stall meter: a stall before a capture counts (\(Int(before * 1000)) ms)", before >= 0.29)
        try? await Task.sleep(for: .milliseconds(100))
        _ = stall.take()
        let c0 = Date()
        _ = ink()
        let span = Date().timeIntervalSince(c0)
        try? await Task.sleep(for: .milliseconds(50))
        let own = stall.take()
        step("stall meter: the capture's own \(Int(span * 1000)) ms does not count (\(Int(own * 1000)) ms)", own < 0.05)

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
            if n < 40 { stall.pause(); capture(win, to: "\(dir)/churn-\(ConversationView.page)-\(name)-blank.png"); stall.resume() }
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
        // Scrolled to the top for Show earlier, to the bottom for Jump to latest.
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

        // 8. The reader scrolls up to the top: older rows load by themselves (no button press), and the message that was at
        // the top of the view stays where it was (the rows come in above it, out of view). At the app's page size: a page as
        // big as the window would replace every row on screen, the one on top too.
        if ConversationView.page < ConversationWindow.maxRows {
            /// The topmost message in view: its text and its distance from the top of the view.
            func topMessage() -> (text: String, y: CGFloat)? {
                let b = sv.contentView.bounds, top = b.minY + sv.contentInsets.top
                return Self.all(MessageTextView.self, in: host)
                    .map { (String($0.string.prefix(80)), $0.convert($0.bounds, to: sv.contentView)) }
                    .filter { $0.1.maxY > top + 10 && $0.1.minY < b.maxY }
                    .min { $0.1.minY < $1.1.minY }.map { ($0.0, $0.1.minY - top) }
            }
            func y(of text: String) -> CGFloat? {
                let top = sv.contentView.bounds.minY + sv.contentInsets.top
                return Self.all(MessageTextView.self, in: host).first { String($0.string.prefix(80)) == text }.map { $0.convert($0.bounds, to: sv.contentView).minY - top }
            }
            // Just outside the zone that loads, then into it in one move: the top message is read before the load runs.
            let outside = NSPoint(x: 0, y: -sv.contentInsets.top + ConversationView.nearTop + 400)
            for _ in 0..<2 { sv.contentView.scroll(to: outside); sv.reflectScrolledClipView(sv.contentView); try? await Task.sleep(for: .milliseconds(500)) }
            _ = stall.take()
            sv.contentView.scroll(to: NSPoint(x: 0, y: -sv.contentInsets.top)); sv.reflectScrolledClipView(sv.contentView)
            let before = topMessage(), count = Self.all(MessageTextView.self, in: host).count
            try? await Task.sleep(for: .milliseconds(900))
            let now = Self.all(MessageTextView.self, in: host).count, loaded = now > count
            let after = before.flatMap { y(of: $0.text) }
            step("autoload: at the top, older rows load without a press (\(count) -> \(now) messages)", loaded)
            step("autoload: after the load, the top message stays in place (\(before.map { Int($0.y) } ?? -1) -> \(after.map { Int($0) } ?? -1) pt)",
                 loaded && before != nil && after != nil && abs(after! - before!.y) < 3)
            stall.pause(); capture(win, to: "\(dir)/churn-\(ConversationView.page)-autoload.png"); stall.resume()
            await settle("autoload")
            ConversationProbe.pressLatest?()
            try? await Task.sleep(for: .milliseconds(600))

            /// Just outside the zone that loads, then into it in one move.
            func intoTop() async {
                let outside = NSPoint(x: 0, y: -sv.contentInsets.top + ConversationView.nearTop + 400)
                for _ in 0..<2 { sv.contentView.scroll(to: outside); sv.reflectScrolledClipView(sv.contentView); try? await Task.sleep(for: .milliseconds(500)) }
                sv.contentView.scroll(to: NSPoint(x: 0, y: -sv.contentInsets.top)); sv.reflectScrolledClipView(sv.contentView)
            }
            /// The numbers of the "Even reply" rows on hand, oldest first.
            func evens() -> [Int] {
                Self.all(MessageTextView.self, in: host).compactMap { Int($0.string.dropFirst("Even reply ".count).prefix { $0.isNumber }) }.sorted()
            }

            // 8b. A window at the cap, scrolled back (Show earlier past the cap), takes a page above and drops one below. Rows
            // of one height: the content height stays the same. Groups of five rows, a tool row at each end: the row on top of
            // the window is a tool row that merges with the older tool row above it. The top message stays in place all the same.
            holder.items = ChurnData.even(3000)
            try? await Task.sleep(for: .milliseconds(600))
            await scroll(top: false)
            ConversationProbe.pressEarlier?()
            try? await Task.sleep(for: .milliseconds(600))
            let latest = ConversationProbe.latest
            await intoTop()
            let capBefore = topMessage(), capOld = evens()
            _ = stall.take()
            try? await Task.sleep(for: .milliseconds(900))
            let capNew = evens()
            let capLoaded = !capOld.isEmpty && !capNew.isEmpty && capNew[0] < capOld[0] && capNew.last! < capOld.last!
            let capAfter = capBefore.flatMap { y(of: $0.text) }
            step("autoload-cap: at the cap, older rows come in and newer go (Jump to latest \(latest.height > 0), rows \(capOld.first ?? -1)…\(capOld.last ?? -1) -> \(capNew.first ?? -1)…\(capNew.last ?? -1))",
                 latest.height > 0 && capLoaded)
            step("autoload-cap: the top message stays in place (\(capBefore.map { Int($0.y) } ?? -1) -> \(capAfter.map { Int($0) } ?? -1) pt)",
                 capLoaded && capBefore != nil && capAfter != nil && abs(capAfter! - capBefore!.y) < 3)
            await settle("autoload-cap")
            ConversationProbe.pressLatest?()
            try? await Task.sleep(for: .milliseconds(600))

            // 8c. Past the oldest row of the log, near the top again: no more reads of the log.
            holder.items = ChurnData.even(120)
            holder.load = { @MainActor [holder] in holder.reads += 1; return false }
            try? await Task.sleep(for: .milliseconds(600))
            for _ in 0..<3 { await intoTop(); try? await Task.sleep(for: .milliseconds(900)) }
            step("autoload-end: after the log said nothing older, no more reads (\(holder.reads), want 1)", holder.reads == 1)

            // 8d. Another session in the same pane (the view stays): its older rows read again. It starts with no rows (the
            // empty view, not the list, sees the switch), then its rows come. Fewer rows than a page, so "Show earlier" is a
            // read of the log.
            holder.items = []
            holder.session = "churn-b"
            try? await Task.sleep(for: .milliseconds(600))
            holder.items = ChurnData.even(30)
            holder.reads = 0
            holder.load = { @MainActor [holder] in holder.reads += 1; return true }
            try? await Task.sleep(for: .milliseconds(600))
            ConversationProbe.pressEarlier?()
            try? await Task.sleep(for: .milliseconds(600))
            step("autoload-session: another session in the pane reads its older rows (\(holder.reads), want 1)", holder.reads == 1)
            holder.load = nil
            holder.session = "churn-a"
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
    /// The view's read of older log rows (nil: rows in memory only).
    var load: (() async -> Bool)?
    var reads = 0
    var session: String? = "churn-a"
    init(items: [ConversationItem]) { self.items = items }
}

/// The pane's shape: ConversationView with a composer-like bar under it (PaneView uses paneBar the same way).
private struct ChurnView: View {
    let holder: ChurnHolder
    var body: some View {
        ConversationView(items: holder.items, agentName: "churn", loadState: .ready, session: holder.session, onLoadEarlier: holder.load)
            .paneBar(.top) { Text("churn · label").font(.caption).frame(maxWidth: .infinity).frame(height: 28) }
            .paneBar(.bottom) {
                // The real composer (a text view that grows with its text), plus room for a taller bar.
                VStack(spacing: 0) {
                    ComposerView(agentName: "churn", draft: ComposerDraft(text: "A draft reply"), onSend: { _ in })
                    Color.clear.frame(height: max(0, holder.bottomBar - 64))
                }
            }
            .softScrollEdges([.top, .bottom])
    }
}

@MainActor @Observable private final class ProbeHolder { var shown = true; var generation = 0 }

/// A short conversation with a Show earlier button on screen.
private struct ProbeView: View {
    let holder: ProbeHolder
    var body: some View {
        if holder.shown {
            ConversationView(items: Array(ChurnData.items(3)), agentName: "probe", loadState: .ready, onLoadEarlier: { false })
                .id(holder.generation)
        }
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
    /// The check's own work starts: the gap so far (an app stall before it) counts, the work's own span does not.
    func pause() { worst = max(worst, Date().timeIntervalSince(last)) }
    func resume() { last = Date() }
    func stop() { timer?.invalidate() }
}

/// Synthetic conversation: user turns, replies of mixed length (paragraphs, lists, code), tool chips between.
enum ChurnData {
    /// Rows of one height, no times: groups of five (a tool row, three one-line replies, a tool row), so two tool rows
    /// meet at each group's edge and merge into one.
    static func even(_ n: Int) -> [ConversationItem] {
        (0..<n).map { i in
            i % 5 == 0 || i % 5 == 4
                ? ConversationItem(id: "et\(i)", kind: .toolChips([ToolChip(symbol: "doc.text", text: "Read a file",
                                                                       id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", i))!)]))
                : ConversationItem(id: "ea\(i)", kind: .assistantText("Even reply \(i)."))
        }
    }

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
