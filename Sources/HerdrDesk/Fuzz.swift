import HerdrKit
import SwiftUI
import AppKit

/// `HerdrDesk --fuzz <seconds> [--seed N] --read-only`: off-screen random-interaction run (activation policy .prohibited).
/// Uses `HerdrStore.previewMutate`: a preview tree that is added to, removed from and re-stated at random,
/// on a session that does not exist. Writes are off (`--read-only`), so no herdr server is ever written to.
/// Every 50 ms one step: a model action, a tree mutation, or a synthetic click at a random point of the window.
/// A watchdog thread fails the run when the main thread stays silent for 2 s.
@MainActor
enum FuzzRunner {
    private final class Heartbeat: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date()
        private var step = 0
        private var what = "start"
        private var maxGap: TimeInterval = 0
        private var finished = false
        func finish() { lock.lock(); finished = true; lock.unlock() }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
        func beat(_ step: Int, _ what: String) {
            lock.lock(); let now = Date(); maxGap = max(maxGap, now.timeIntervalSince(t)); t = now; self.step = step; self.what = what; lock.unlock()
        }
        func snapshot() -> (age: TimeInterval, step: Int, what: String, maxGap: TimeInterval) {
            lock.lock(); defer { lock.unlock() }; return (Date().timeIntervalSince(t), step, what, maxGap)
        }
    }

    static func run(seconds: Double, seed: UInt64, model: AppModel) async {
        guard !model.writesEnabled else {
            print("fuzz: refusing to run with writes enabled; add --read-only"); exit(3)
        }
        let beat = Heartbeat()
        let pid = ProcessInfo.processInfo.processIdentifier
        let auditDir = FileManager.default.currentDirectoryPath + "/build/audit"
        try? FileManager.default.createDirectory(atPath: auditDir, withIntermediateDirectories: true)

        // Watchdog: independent thread, so it still runs when the main thread is stuck.
        let dog = Thread {
            while true {
                Thread.sleep(forTimeInterval: 0.2)
                let s = beat.snapshot()
                guard s.age > 1.0, !beat.isFinished else { continue }
                // Stalled for a second: sample now, while the main thread is still stuck, then judge.
                let out = "\(auditDir)/fuzz-hang-\(Int(Date().timeIntervalSince1970)).txt"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                p.arguments = ["\(pid)", "1", "-file", out]
                try? p.run(); p.waitUntilExit()
                let after = beat.snapshot()
                if after.age > 2.0 || after.maxGap > 2.0 {
                    print("fuzz: HANG: main thread silent for \(String(format: "%.1f", max(after.age, after.maxGap))) s at step \(s.step) (\(s.what)); sample: \(out)")
                    exit(2)
                }
                try? FileManager.default.moveItem(atPath: out, toPath: out.replacingOccurrences(of: "fuzz-hang-", with: "fuzz-stall-"))   // slow but alive
            }
        }
        dog.stackSize = 1 << 20
        dog.start()

        // Window with the real root view (toolbar, split view, sheets), off-screen.
        let size = NSSize(width: 1280, height: 820)
        let host = NSHostingView(rootView: RootView().environment(model).frame(minWidth: 960, minHeight: 600))
        host.frame = NSRect(origin: .zero, size: size)
        let win = OffscreenWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.titleVisibility = .hidden
        WindowChrome.apply(win)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        win.orderFrontRegardless()

        var rng = seed == 0 ? 0xA5A5_1234_5678_9ABC : seed
        func next(_ n: Int) -> Int {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            return Int(rng % UInt64(max(n, 1)))
        }
        func pick<T>(_ a: [T]) -> T? { a.isEmpty ? nil : a[next(a.count)] }
        func allTabs() -> [(Workspace, Tab)] { model.store.workspaces.flatMap { w in w.tabs.map { (w, $0) } } }
        func allPanes() -> [(Tab, Pane)] { allTabs().flatMap { _, t in t.panes.map { (t, $0) } } }

        func click(count: Int = 1) {
            guard let cv = win.contentView else { return }
            let b = cv.bounds
            let pt = NSPoint(x: CGFloat(next(max(Int(b.width), 1))), y: CGFloat(next(max(Int(b.height), 1))))
            func ev(_ k: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: k, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)
            }
            // Queue the mouse-up first: AppKit's mouse-down handling (window drag / resize hysteresis) runs a nested
            // event loop that waits for it. Without this a synthetic click blocks the main thread by itself.
            if let up = ev(.leftMouseUp), let down = ev(.leftMouseDown) { win.postEvent(up, atStart: false); win.sendEvent(down) }
        }

        var counts: [String: Int] = [:]
        func act(_ i: Int) async {
            let n = next(22)
            let name: String
            switch n {
            case 0, 1: name = "mutate"; for _ in 0..<(1 + next(3)) { model.store.fuzzStep() }
            case 2: name = "select-workspace"; if next(6) == 0 { model.workspaceID = "gone-ws" } else if let (w, _) = pick(allTabs()) { model.select(workspace: w.id) }
            case 3: name = "select-tab"; if next(6) == 0 { model.tabID = "gone-tab" } else if let (w, t) = pick(allTabs()) { model.select(tab: t, in: w) }
            case 4: name = "screen"; model.screen = pick([Screen.tab, .inbox, .overview, .search, .tab])!
            case 5: name = "zoom"; if let (t, p) = pick(allPanes()) { if next(2) == 0 { model.toggleZoom(p, in: t) } else { model.toggleZoomFocused() } }
            case 6: name = "split"; model.splitFocused(next(2) == 0 ? .right : .down)
            case 7: name = "new-close-tab"; if next(2) == 0 { model.newTab() } else { model.closeTab() }
            case 8: name = "rename"; if let (_, t) = pick(allTabs()) { if next(2) == 0 { model.renamingTabID = t.id } else { model.rename(t, to: "x\(i)") } }
            case 9: name = "terminal-sheet"; model.showTerminal.toggle()
            case 10: name = "sidebar"; model.setSidebarVisibility(pick([NavigationSplitViewVisibility.all, .detailOnly, .automatic, .doubleColumn])!)
            case 11: name = "resize"; win.setContentSize(NSSize(width: CGFloat(960 + next(800)), height: CGFloat(600 + next(300))))
            case 12, 13, 14: name = "click"; click(count: 1 + next(2))
            case 15: name = "send"; if let (_, p) = pick(allPanes()) { model.send("hello 你好 \(i)", to: p) }
            case 16: name = "search-text"; model.searchText = pick(["", "a", "tab", "你", "zzzz"])!
            case 17: name = "approve"; if let (_, p) = pick(allPanes()) { model.approve(pane: p, allow: next(2) == 0) }
            case 18: name = "check-prompt"; if let (_, p) = pick(allPanes()) { await model.checkPrompt(for: p) }
            case 19: name = "load-earlier"; if let (_, p) = pick(allPanes()) { _ = await model.store.loadEarlier(paneId: p.id) }
            case 20: name = "appearance"; win.appearance = NSAppearance(named: next(2) == 0 ? .darkAqua : .aqua)
            default: name = "next-prev"; if next(2) == 0 { model.cycleTab(next(2) == 0 ? 1 : -1) } else { model.cycleWorkspace(next(2) == 0 ? 1 : -1) }
            }
            counts[name, default: 0] += 1
            beat.beat(i, name)
        }

        print("fuzz: start \(seconds) s, seed \(seed), pid \(pid)")
        let start = Date()
        var i = 0
        while Date().timeIntervalSince(start) < seconds {
            i += 1
            beat.beat(i, "tick")
            await act(i)
            try? await Task.sleep(for: .milliseconds(50))
        }
        beat.finish()   // the log query below takes seconds on purpose; the watchdog stops here
        win.orderOut(nil)

        // os_log faults of this process during the run.
        let span = Int(Date().timeIntervalSince(start)) + 15
        let faults: [String] = await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            p.arguments = ["show", "--last", "\(span)s", "--style", "compact", "--predicate", "processID == \(pid) AND messageType == fault"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
                .filter { !$0.hasPrefix("Timestamp") && !$0.hasPrefix("Filtering the log") && !$0.isEmpty }
        }.value
        let multi = faults.filter { $0.contains("multiple times per frame") }.count
        let envf = faults.filter { $0.contains("Environment") }.count
        var report = "## fuzz run \(ISO8601DateFormatter().string(from: Date()))\n\n"
        report += "- steps: \(i) in \(Int(Date().timeIntervalSince(start))) s, seed \(seed)\n- crash: 0 (process alive)\n- hang: 0 (watchdog 2 s)\n"
        report += "- os_log faults: \(faults.count) (multiple-times-per-frame: \(multi), environment: \(envf))\n"
        report += "- actions: " + counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + "\n"
        for f in faults.prefix(10) { report += "  - \(f.prefix(220))\n" }
        report += "\n"
        print(report)
        if let h = FileHandle(forWritingAtPath: auditDir + "/fuzz.md") { h.seekToEndOfFile(); h.write(Data(report.utf8)); try? h.close() }
        else { try? report.write(toFile: auditDir + "/fuzz.md", atomically: true, encoding: .utf8) }
        exit(0)
    }
}
