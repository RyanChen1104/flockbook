import AppKit
import HerdrKit
import SwiftUI

/// Offscreen check (`--test-open-latest-log <file.jsonl>`): a pane opens a session log file the way the store reads it
/// (the short tail first, then the backfill in front) and must rest at the newest message. Reads only that file; no
/// herdr connection. Opens it three times (as a tab switch would), in a full-screen-sized window.
extension ContentTests {
    static func openLatestLog(_ args: [String]) async {
        guard let i = args.firstIndex(of: "--test-open-latest-log"), args.indices.contains(i + 1), args[i + 1].hasSuffix(".jsonl") else {
            print("open-latest-log: usage: HerdrDesk --test-open-latest-log <absolute path>.jsonl"); exit(2)
        }
        let path = args[i + 1]
        var failures = 0
        func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("open-latest-log: \(n) \(ok ? "ok" : "FAIL")") }
        let holder = OpenLatestHolder()
        let size = NSSize(width: 1512, height: 945)
        let host = NSHostingView(rootView: OpenLatestView(holder: holder))
        host.frame = NSRect(origin: .zero, size: size)
        let win = OffscreenWindow(contentRect: host.frame, styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        win.contentView = host; win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()

        func conversation() -> NSScrollView? {
            func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
            return views(host).compactMap { $0 as? NSScrollView }.max { $0.bounds.height < $1.bounds.height }
        }
        func gap() -> CGFloat? {
            guard let s = conversation(), let d = s.documentView else { return nil }
            let visibleBottom = s.contentView.bounds.origin.y + s.contentView.bounds.height
            return d.isFlipped ? d.frame.height + s.contentInsets.bottom - visibleBottom : s.contentView.bounds.origin.y + s.contentInsets.bottom
        }
        func show(_ g: CGFloat?) -> String { g.map { String(format: "%.0f", $0) } ?? "-" }

        for round in 1...3 {
            holder.pane = "p\(round)"; holder.items = []; holder.load = .loading
            let log = SessionLog(sessionId: path)
            let feed = Task { @MainActor in
                for await snap in log.snapshots() { holder.items = snap.items; holder.load = snap.load }
            }
            var trace: [String] = []
            for t in [0.3, 0.7, 1.5, 3.0, 5.0, 8.0] {
                try? await Task.sleep(for: .seconds(t - (trace.isEmpty ? 0 : [0.3, 0.7, 1.5, 3.0, 5.0, 8.0][trace.count - 1])))
                trace.append("\(t)s:\(show(gap()))/\(holder.items.count)")
            }
            let g = gap()
            step("open \(round): at the newest message (gap/rows \(trace.joined(separator: " ")), doc \(Int(conversation()?.documentView?.frame.height ?? 0)))", (g ?? 99) < 4)
            capture(win, to: "\(dir)/open-latest-log-\(round).png")
            feed.cancel()
        }
        // The agent keeps writing while the pane is open: env OPEN_LATEST_APPEND=<file.jsonl>, its lines go to the end of the log, a few at a time.
        if let more = ProcessInfo.processInfo.environment["OPEN_LATEST_APPEND"],
           let text = try? String(contentsOfFile: more, encoding: .utf8), let fh = FileHandle(forWritingAtPath: path) {
            holder.pane = "live"; holder.items = []; holder.load = .loading
            let log = SessionLog(sessionId: path)
            let feed = Task { @MainActor in for await snap in log.snapshots() { holder.items = snap.items; holder.load = snap.load } }
            try? await Task.sleep(for: .seconds(1.5))
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            var worst: CGFloat = 0
            for chunk in stride(from: 0, to: lines.count, by: 3) {
                fh.seekToEndOfFile()
                fh.write(Data((lines[chunk..<min(chunk + 3, lines.count)].joined(separator: "\n") + "\n").utf8))
                try? await Task.sleep(for: .milliseconds(250))
                worst = max(worst, gap() ?? 0)
            }
            try? fh.close()
            try? await Task.sleep(for: .seconds(2))
            step("agent writing: \(lines.count) lines appended, rows \(holder.items.count), largest gap between writes \(show(worst)), at rest \(show(gap()))", (gap() ?? 99) < 4)
            capture(win, to: "\(dir)/open-latest-log-live.png")
            feed.cancel()
        }
        win.orderOut(nil)
        print("open-latest-log: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        exit(failures == 0 ? 0 : 1)
    }
}
