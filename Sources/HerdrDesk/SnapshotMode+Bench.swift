import AppKit
import HerdrKit
import SwiftUI

/// Offscreen bench for a long session (`--bench-conversation <log.jsonl>`): the log is read through SessionLog the way the
/// app reads it, then shown in ConversationView in an offscreen window. Prints timings; no pass/fail. Under 60 s.
/// Measures: first view and 2 MB backfill (HerdrKit), "Show earlier" re-parse, one-line append (write -> snapshot),
/// first layout, scroll frame time, layout after an appended item. Works on a copy in a temp folder; the log is only read.
extension ContentTests {
    static func benchConversation(_ args: [String]) async {
        guard let i = args.firstIndex(of: "--bench-conversation"), args.indices.contains(i + 1),
              let all = try? Data(contentsOf: URL(fileURLWithPath: args[i + 1])) else {
            print("bench: usage: HerdrDesk --bench-conversation <log.jsonl>"); exit(2)
        }
        let started = Date()
        func ms(_ d: Duration) -> String { String(format: "%.1f ms", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
        func stats(_ xs: [Duration]) -> String {
            let s = xs.sorted(); guard !s.isEmpty else { return "-" }
            return "median \(ms(s[s.count / 2])), p95 \(ms(s[min(s.count - 1, s.count * 95 / 100)])), max \(ms(s.last!)) (n \(s.count))"
        }
        let clock = ContinuousClock()

        // The log minus its last 40 lines; those lines are appended one by one later.
        var lines = all.split(separator: 0x0A, omittingEmptySubsequences: true)
        let tail = Array(lines.suffix(40)); lines.removeLast(min(40, lines.count))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("flockbook-bench-\(UUID().uuidString).jsonl")
        var head = Data(); head.reserveCapacity(all.count)
        for l in lines { head.append(contentsOf: l); head.append(0x0A) }
        try? head.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        print("bench: log \(all.count / 1_000_000) MB, \(lines.count + tail.count) lines")

        // (A) HerdrKit: first view, backfill, Show earlier, append.
        let log = SessionLog(sessionId: tmp.path, agent: "claude")
        var it = log.snapshots(pollInterval: .seconds(30)).makeAsyncIterator()
        let t0 = clock.now
        var snap = await it.next()
        while let s = snap, s.items.isEmpty { snap = await it.next() }
        print("bench: kit first view \(ms(clock.now - t0)), \(snap?.items.count ?? 0) items")
        snap = await it.next()
        print("bench: kit backfill to 2 MB \(ms(clock.now - t0)), \(snap?.items.count ?? 0) items")
        var earlier: [Duration] = []
        for _ in 0..<5 {
            let t = clock.now
            _ = await log.loadEarlier()
            snap = await it.next()
            earlier.append(clock.now - t)
        }
        print("bench: kit Show earlier (+2 MB each, whole range re-parsed): \(earlier.map(ms).joined(separator: ", ")), \(snap?.items.count ?? 0) items")
        var appends: [Duration] = []
        let fh = try? FileHandle(forWritingTo: tmp)
        for l in tail.prefix(20) {
            _ = try? fh?.seekToEnd()
            let t = clock.now
            try? fh?.write(contentsOf: Data(l) + Data([0x0A]))
            snap = await it.next()
            appends.append(clock.now - t)
        }
        print("bench: kit append one line (write -> snapshot): \(stats(appends))")
        let items = snap?.items ?? []

        // (B) UI: ConversationView with those items.
        let holder = BenchItems(items: Array(items.dropLast(20)))
        let size = NSSize(width: 1200, height: 800)
        let t1 = clock.now
        let host = NSHostingView(rootView: BenchConversation(holder: holder).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = host; win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()
        host.layoutSubtreeIfNeeded(); win.displayIfNeeded()
        print("bench: ui first layout \(ms(clock.now - t1)) (\(holder.items.count) items, ConversationView shows the last 150)")
        try? await Task.sleep(for: .seconds(1))
        func atBottom(_ sv: NSScrollView) -> String {
            let b = sv.contentView.bounds, doc = sv.documentView?.frame.height ?? 0
            return "offset \(Int(b.maxY)) of \(Int(doc)) (\(doc - b.maxY <= 40 ? "at the bottom" : "NOT at the bottom"))"
        }

        func scrollView(_ v: NSView) -> NSScrollView? {
            if let s = v as? NSScrollView, (s.documentView?.frame.height ?? 0) > s.frame.height { return s }
            for c in v.subviews { if let s = scrollView(c) { return s } }
            return nil
        }
        if let sv = scrollView(host) {
            print("bench: ui after first layout: \(atBottom(sv))")
            var frames: [Duration] = []
            let docH = sv.documentView?.frame.height ?? 0
            var y = sv.contentView.bounds.origin.y
            for _ in 0..<60 {
                y = max(0, y - 120)
                let t = clock.now
                sv.contentView.scroll(to: NSPoint(x: 0, y: y)); sv.reflectScrolledClipView(sv.contentView)
                host.layoutSubtreeIfNeeded(); win.displayIfNeeded()
                frames.append(clock.now - t)
                try? await Task.sleep(for: .milliseconds(5))
            }
            print("bench: ui scroll frame (120 pt steps up, document \(Int(docH)) pt): \(stats(frames))")
        } else { print("bench: ui scroll: no scroll view found") }

        var layouts: [Duration] = []
        let rounds = ProcessInfo.processInfo.environment["BENCH_ROUNDS"].flatMap(Int.init) ?? 1   // >1: long loop for `sample`
        if rounds > 1 { print("bench: pid \(ProcessInfo.processInfo.processIdentifier) append loop x\(rounds)"); fflush(stdout) }
        for r in 0..<rounds {
            if r > 0 { holder.items.removeLast(20); host.layoutSubtreeIfNeeded() }
        for item in items.suffix(20) {
            let t = clock.now
            holder.items.append(item)
            host.layoutSubtreeIfNeeded(); win.displayIfNeeded()
            layouts.append(clock.now - t)
            try? await Task.sleep(for: .milliseconds(20))
        }
        }
        print("bench: ui append one item (state -> laid out): \(stats(layouts))")
        if let sv = scrollView(host) {
            // Back to the bottom (the reader was scrolled up), then appends follow it.
            sv.contentView.scroll(to: NSPoint(x: 0, y: (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height))
            sv.reflectScrolledClipView(sv.contentView)
            try? await Task.sleep(for: .milliseconds(500))
            holder.items.removeLast(5); try? await Task.sleep(for: .milliseconds(300))
            for item in items.suffix(5) { holder.items.append(item); try? await Task.sleep(for: .milliseconds(150)) }
            try? await Task.sleep(for: .milliseconds(800))
            print("bench: ui after appends at the bottom: \(atBottom(sv))")
        }

        // Same items, a new array (a snapshot of an unrelated session also re-renders every conversation that reads the store).
        var same: [Duration] = []
        for _ in 0..<20 {
            let t = clock.now
            holder.items = Array(holder.items)
            host.layoutSubtreeIfNeeded(); win.displayIfNeeded()
            same.append(clock.now - t)
            try? await Task.sleep(for: .milliseconds(20))
        }
        print("bench: ui same items again (re-render): \(stats(same))")
        win.orderOut(nil)
        print("bench: total \(Int(Date().timeIntervalSince(started))) s")
        exit(0)
    }
}

@MainActor @Observable private final class BenchItems {
    var items: [ConversationItem]
    init(items: [ConversationItem]) { self.items = items }
}

private struct BenchConversation: View {
    let holder: BenchItems
    var body: some View {
        ConversationView(items: holder.items, agentName: "bench", loadState: .ready)
    }
}
