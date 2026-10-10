import Foundation
@testable import HerdrKit

// Read-only modes: benchmarks, watch, sweeps. Each returns when its flag is absent, else exits.

// `HerdrKitChecks --watch <seconds> [session]`: runs a real HerdrStore (read-only: snapshot + event subscription) and
// fails if `connected` ever drops after it first became true, or if the event stream never opens.
@MainActor func modeWatch() async throws {
    if let i = CommandLine.arguments.firstIndex(of: "--watch") {
        let a = CommandLine.arguments
        let secs = a.count > i + 1 ? Int(a[i + 1]) ?? 60 : 60
        let session = a.count > i + 2 ? HerdrSession.named(a[i + 2]) : HerdrSession.default()
        let store = HerdrStore(session: session)
        store.start()
        let counter = EventCounter()
        let evTask = Task {
            do { for try await _ in HerdrClient(session: session).events() { await counter.bump() } }
            catch { await counter.fail("\(error)") }
        }
        var up = 0, drops = 0, everUp = false
        for t in 1...secs {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if store.connected { up += 1; everUp = true } else if everUp { drops += 1 }
            if t % 10 == 0 { print("t=\(t)s connected=\(store.connected) workspaces=\(store.workspaces.count) events=\(await counter.count)") }
        }
        evTask.cancel(); store.stop()
        let n = await counter.count, err = await counter.error
        check(everUp, "watch: connected became true")
        check(drops == 0, "watch: connected never dropped (drops=\(drops), up \(up)/\(secs)s)")
        check(n >= 1 && err == nil, "watch: event stream opened and stayed open (events=\(n), error=\(err ?? "none"))")
        print(failures == 0 ? "OK watch \(secs)s: connected \(up)/\(secs)s, events=\(n)" : "FAILED watch")
        exit(failures == 0 ? 0 : 1)
    }
}

// `HerdrKitChecks --perf [session]`: read-only performance baseline against a real session (default session unless named):
// connect time, cold first-display latency per agent log, time until every agent has its conversation, RSS, idle CPU.
@MainActor func modePerf() async throws {
    if let i = CommandLine.arguments.firstIndex(of: "--perf") {
        let a = CommandLine.arguments
        let session = a.count > i + 1 && !a[i + 1].hasPrefix("-") ? HerdrSession.named(a[i + 1]) : HerdrSession.default()
        /// Physical footprint (what Activity Monitor calls Memory); unlike resident size it does not shrink when the OS compresses pages.
        func rssMB() -> Double {
            var info = task_vm_info_data_t(); var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
            return Double(info.phys_footprint) / 1_048_576
        }
        func cpuSec() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6 }
        func ms(_ t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }
        print("perf: rss at start \(Int(rssMB())) MB")
        let store = HerdrStore(session: session)
        if ProcessInfo.processInfo.environment["PERF_NO_VISIBLE"] == nil { store.setVisibleSessions([]) }   // like AppModel
        let t0 = Date()
        store.start()
        while !store.connected && ms(t0) < 10_000 { try await Task.sleep(nanoseconds: 10_000_000) }
        print("perf: connect+snapshot \(ms(t0)) ms, workspaces=\(store.workspaces.count)")
        let agents = store.workspaces.flatMap(\.tabs).flatMap(\.panes).compactMap(\.agent)
        let withSession = agents.filter { $0.sessionId != nil }
        print("perf: agents=\(agents.count) withSession=\(withSession.count) rss=\(Int(rssMB())) MB")

        // Cold: a fresh SessionLog per agent, time until it first has items (what a tab switch costs the first time).
        let tourOnly = ProcessInfo.processInfo.environment["PERF_TOUR_ONLY"] != nil
        var cold: [Int] = [], empty = 0
        for ag in withSession where !tourOnly {
            let log = SessionLog(sessionId: ag.sessionId!, codex: ag.kind == "codex")
            var it = log.snapshots(pollInterval: .milliseconds(20)).makeAsyncIterator()
            let t = Date()
            var got = false
            while ms(t) < 6000, let snap = await it.next() { if !snap.items.isEmpty { got = true; break } }
            if got { cold.append(ms(t)) } else { empty += 1 }
        }
        cold.sort()
        func pct(_ q: Double) -> Int { cold.isEmpty ? 0 : cold[min(cold.count - 1, Int(Double(cold.count) * q))] }
        print("perf: cold first display (ms) n=\(cold.count) empty/missing=\(empty) median=\(pct(0.5)) p95=\(pct(0.95)) max=\(cold.last ?? 0) sum=\(cold.reduce(0, +))")
        print("perf: rss after cold pass \(Int(rssMB())) MB")

        // All at once through the store (what visiting every tab does), then wait until each has items.
        store.maxLiveLogs = tourOnly ? Int(ProcessInfo.processInfo.environment["PERF_LIVE"] ?? "8")! : 1000
        let tAll = Date(), rssBefore = rssMB()
        for ag in withSession { _ = store.conversation(for: ag.sessionId) }
        var ready = 0
        while !tourOnly, ms(tAll) < 40_000 {
            ready = withSession.filter { !store.conversation(for: $0.sessionId).isEmpty }.count
            if ready >= withSession.count - empty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        print("perf: all agents loaded via store: \(ready)/\(withSession.count - empty) in \(ms(tAll)) ms, rss \(Int(rssBefore)) -> \(Int(rssMB())) MB")
        let itemTotal = withSession.reduce(0) { $0 + store.conversation(for: $1.sessionId).count }
        print("perf: items total=\(itemTotal)")

        // Warm switch cost: conversation(for:) on an already tracked session.
        let tw = Date()
        let warmSet = tourOnly ? Array(withSession.prefix(8)) : withSession
        for _ in 0..<200 { for ag in warmSet { _ = store.conversation(for: ag.sessionId) } }
        let warmUs = Double(ms(tw)) * 1000 / Double(max(1, 200 * warmSet.count))
        print("perf: warm conversation(for:) ~\(String(format: "%.1f", warmUs)) us per call")

        // App-like: visit every tab in turn with the default live-log limit; footprint after the whole tour.
        store.maxLiveLogs = Int(ProcessInfo.processInfo.environment["PERF_LIVE"] ?? "8")!
        var visit: [Int] = []
        for ag in withSession {
            let t = Date()
            store.setVisibleSessions([ag.sessionId!])    // what AppModel does when a tab is shown
            while ms(t) < 5_000, store.conversation(for: ag.sessionId).isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
            visit.append(ms(t))
        }
        visit.sort()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        print("perf: tour with limit 8 (ms) median=\(visit[visit.count / 2]) max=\(visit.last ?? 0), rss \(Int(rssMB())) MB")

        // Idle CPU over 10 s with every log tailed.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let c0 = cpuSec(), w0 = Date()
        try await Task.sleep(nanoseconds: 10_000_000_000)
        let pct = (cpuSec() - c0) / Date().timeIntervalSince(w0) * 100
        print("perf: idle CPU \(String(format: "%.1f", pct)) % over 10 s with <=8 logs tailed, rss \(Int(rssMB())) MB")
        store.stop()
        exit(0)
    }
}

// `HerdrKitChecks --polish-bench`: store timing against a fake herdr socket (reconnect, event latency, idle polling),
// then event latency against c9-input-test (renames its own throwaway workspace). Never the default session.
@MainActor func modePolishBench() async throws {
    if CommandLine.arguments.contains("--polish-bench") {
        func ms(_ t: Date) -> Double { Date().timeIntervalSince(t) * 1000 }
        func cpuSec() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6 }
        func waitFor(_ sec: Double, _ ok: () -> Bool) async -> Double? {
            let t = Date(); while ms(t) < sec * 1000 { if ok() { return ms(t) }; try? await Task.sleep(nanoseconds: 2_000_000) }; return nil
        }
        func med(_ a: [Double]) -> String { let s = a.sorted(); return s.isEmpty ? "-" : String(format: "%.0f", s[s.count / 2]) }
        func mx(_ a: [Double]) -> String { String(format: "%.0f", a.max() ?? 0) }
        let only = ProcessInfo.processInfo.environment["BENCH_ONLY"] ?? ""
        let fake = FakeHerdr(path: NSTemporaryDirectory() + "hkfake-\(getpid()).sock")
        try fake.start()
        let store = HerdrStore(session: HerdrSession(name: "fake", socketPath: fake.path))
        store.start()
        _ = await waitFor(5) { store.connected && store.workspaces.first?.label == "v0" }
        try? await Task.sleep(nanoseconds: 500_000_000)

        if only.isEmpty || only == "latency" {
            var lat: [Double] = []
            for n in 1...20 {
                fake.label = "e\(n)"; let t = Date(); fake.pushEvent()
                if let d = await waitFor(3, { store.workspaces.first?.label == "e\(n)" }) { lat.append(d) }
                _ = t; try? await Task.sleep(nanoseconds: 250_000_000)
            }
            print("bench: event->store latency (fake) median \(med(lat)) ms, max \(mx(lat)) ms, n=\(lat.count)/20")
        }
        if only.isEmpty || only == "idle" {
            let s0 = fake.snapshotCount, c0 = cpuSec(), t0 = Date()
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            let cpu = (cpuSec() - c0) / Date().timeIntervalSince(t0) * 100
            print("bench: idle 10 s: \(fake.snapshotCount - s0) snapshot requests, CPU \(String(format: "%.2f", cpu)) %")
        }
        if only.isEmpty || only == "reconnect" {
            for down in [0.2, 3.0, 8.0] {
                fake.kill()
                let td = await waitFor(5) { !store.connected }
                try? await Task.sleep(nanoseconds: UInt64(down * 1e9))
                fake.label = "r\(down)"; try fake.start(); let t = Date()
                let tr = await waitFor(15) { store.connected && store.workspaces.first?.label == "r\(down)" }
                print("bench: socket down \(down) s: noticed in \(td.map { String(format: "%.0f", $0) } ?? "never") ms, back \(tr.map { String(format: "%.0f", $0) } ?? "never(>15s)") ms after restart")
                _ = t; try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        store.stop(); fake.kill()

        if only.isEmpty || only == "live" {
            let session = HerdrSession.named("c9-input-test")      // never the default session
            let client = HerdrClient(session: session)
            let live = HerdrStore(session: session)
            live.start()
            _ = await waitFor(5) { live.connected }
            let ws = try await client.createWorkspace(label: "hk-bench", cwd: "/tmp")
            _ = await waitFor(5) { live.workspaces.contains { $0.id == ws } }
            var lat: [Double] = []
            for n in 1...10 {
                let t = Date(); try await client.renameWorkspace(id: ws, to: "hk-bench-\(n)")
                if let _ = await waitFor(5, { live.workspaces.first { $0.id == ws }?.label == "hk-bench-\(n)" }) { lat.append(ms(t)) }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            var snap: [Double] = [], ren: [Double] = []
            for n in 1...10 {
                var t = Date(); _ = try await client.snapshot(); snap.append(ms(t))
                t = Date(); try await client.renameWorkspace(id: ws, to: "hk-rt-\(n)"); ren.append(ms(t))
            }
            print("bench: c9 round trips: snapshot median \(med(snap)) ms, rename median \(med(ren)) ms")
            try await client.closeWorkspace(id: ws)
            print("bench: rename->store latency (c9-input-test) median \(med(lat)) ms, max \(mx(lat)) ms, n=\(lat.count)/10")
            live.stop()
        }
        exit(0)
    }
}

// `HerdrKitChecks --bench-locate`: cost of looking up a missing session id (stat only, no log content read).
@MainActor func modeBenchLocate() async throws {
    if CommandLine.arguments.contains("--bench-locate") {
        var t = Date()
        for _ in 0..<20 { _ = SessionLog.locate(sessionId: "00000000-missing") }
        print("bench: locate(claude, missing) \(String(format: "%.2f", Date().timeIntervalSince(t) * 1000 / 20)) ms")
        t = Date()
        for _ in 0..<5 { _ = SessionLog.locateCodex(sessionId: "00000000-missing") }
        if let id = ProcessInfo.processInfo.environment["CODEX_ID"] {
            let t2 = Date(); for _ in 0..<5 { _ = SessionLog.locateCodex(sessionId: id) }
            func oldLocate(_ sid: String) -> URL? {   // the enumerator lookup before this change, for the before/after number
                guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: NSHomeDirectory() + "/.codex/sessions"), includingPropertiesForKeys: nil) else { return nil }
                for case let u as URL in en where u.lastPathComponent.hasPrefix("rollout-") && u.lastPathComponent.hasSuffix("-\(sid).jsonl") { return u }
                return nil
            }
            let t3 = Date(); for _ in 0..<5 { _ = oldLocate(id) }
            print("bench: old enumerator lookup (recent id) \(String(format: "%.2f", Date().timeIntervalSince(t3) * 1000 / 5)) ms")
            print("bench: locateCodex(recent id) \(String(format: "%.2f", Date().timeIntervalSince(t2) * 1000 / 5)) ms")
        }
        print("bench: locateCodex(missing) \(String(format: "%.2f", Date().timeIntervalSince(t) * 1000 / 5)) ms")
        exit(0)
    }
}

// `HerdrKitChecks --bench-mem [n]`: footprint and first load with n synthetic 12 MB logs tailed like visible tabs.
@MainActor func modeBenchMem() async throws {
    if let i = CommandLine.arguments.firstIndex(of: "--bench-mem") {
        let n = CommandLine.arguments.count > i + 1 ? Int(CommandLine.arguments[i + 1]) ?? 8 : 8
        func fp() -> Double {
            var info = task_vm_info_data_t(); var c = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &c) } }
            return Double(info.phys_footprint) / 1_048_576
        }
        let dir = NSTemporaryDirectory() + "hkmem-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/proj", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // A realistic mix: user text, assistant text with markdown, tool_use + tool_result with large output.
        var chunk = Data()
        let big = String(repeating: "output line with some text 0123456789\\n", count: 120)
        for k in 0..<300 {
            let ts = "2026-10-10T01:\(String(format: "%02d", k % 60)):00.000Z"
            let lines = [
                #"{"type":"user","uuid":"u\#(k)","timestamp":"\#(ts)","message":{"role":"user","content":"please fix item \#(k) in the parser and run the tests"}}"#,
                #"{"type":"assistant","uuid":"a\#(k)","timestamp":"\#(ts)","message":{"role":"assistant","content":[{"type":"text","text":"I will **read** the file `Parser.swift` and then run the tests.\n\n- step one\n- step two"},{"type":"tool_use","id":"t\#(k)","name":"Bash","input":{"command":"swift test --filter P\#(k)"}}]}}"#,
                #"{"type":"user","uuid":"r\#(k)","timestamp":"\#(ts)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t\#(k)","content":"\#(big)"}]}}"#,
            ]
            for l in lines { chunk.append(Data((l + "\n").utf8)) }
        }
        for j in 0..<n {
            let path = dir + "/proj/s\(j).jsonl"
            FileManager.default.createFile(atPath: path, contents: nil)
            let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            while (try fh.offset()) < 12 * 1024 * 1024 { try fh.write(contentsOf: chunk) }
            try fh.close()
        }
        malloc_zone_pressure_relief(nil, 0)
        let base = fp()
        print("bench-mem: footprint before \(Int(base)) MB")
        var firsts: [Double] = [], tasks: [Task<Void, Never>] = [], logs: [SessionLog] = [], firstItems: [Int] = []
        let counts = Locked([Int](repeating: 0, count: n))
        let t0 = Date()
        for j in 0..<n {
            let log = SessionLog(sessionId: "s\(j)"); logs.append(log)
            var it = log.snapshots(projectsDir: dir).makeAsyncIterator()
            let t = Date()
            _ = await it.next()
            let first = await it.next()
            firsts.append(Date().timeIntervalSince(t) * 1000)
            counts.update { $0[j] = first?.items.count ?? 0 }; firstItems.append(first?.items.count ?? 0)
            tasks.append(Task { while let s = await it.next() { counts.update { $0[j] = s.items.count } } })
        }
        let firstCounts = firstItems, opened = Int(Date().timeIntervalSince(t0) * 1000)
        try? await Task.sleep(nanoseconds: 3_000_000_000)    // backfill to 2 MB
        let fullCounts = counts.get()
        firsts.sort()
        print("bench-mem: first load median \(Int(firsts[firsts.count / 2])) ms max \(Int(firsts.last!)) ms; items first \(firstCounts[0]) -> full \(fullCounts[0]); all opened in \(opened) ms")
        print("bench-mem: footprint with \(n) full logs \(Int(fp())) MB (+\(Int(fp() - base)))")
        malloc_zone_pressure_relief(nil, 0)
        print("bench-mem: after pressure relief \(Int(fp())) MB")
        for t in tasks { t.cancel() }; tasks = []; logs = []
        try? await Task.sleep(nanoseconds: 500_000_000)
        malloc_zone_pressure_relief(nil, 0)
        print("bench-mem: after release \(Int(fp())) MB")
        exit(0)
    }
}

// `HerdrKitChecks --bench-parse`: where the parse time goes (per-call costs).
@MainActor func modeBenchParse() async throws {
    if CommandLine.arguments.contains("--bench-parse") {
        let big = String(repeating: "output line with some text 0123456789\n", count: 120)
        var t = Date(); for _ in 0..<1000 { _ = ConversationParser.cut(big) }
        print("bench-parse: cut(4.8 KB) \(String(format: "%.1f", Date().timeIntervalSince(t) * 1000)) us/call")
        t = Date(); for _ in 0..<1000 { _ = ConversationParser.parseTime("2026-10-10T01:02:03.456Z") }
        print("bench-parse: parseTime \(String(format: "%.1f", Date().timeIntervalSince(t) * 1000)) us/call")
        let line = #"{"type":"user","uuid":"r1","timestamp":"2026-10-10T01:02:03.456Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"\#(big.replacingOccurrences(of: "\n", with: "\\n"))"}]}}"#
        t = Date(); for _ in 0..<1000 { _ = try? JSONSerialization.jsonObject(with: Data(line.utf8)) }
        print("bench-parse: JSONSerialization of a 5 KB line \(String(format: "%.1f", Date().timeIntervalSince(t) * 1000)) us/call")
        var p = ConversationParser()
        t = Date(); for k in 0..<1000 {
            p.feed(line: #"{"type":"assistant","uuid":"a\#(k)","timestamp":"2026-10-10T01:02:03.456Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t\#(k)","name":"Bash","input":{"command":"ls"}}]}}"#)
            p.feed(line: line.replacingOccurrences(of: #""t1""#, with: "\"t\(k)\""))
        }
        print("bench-parse: feed tool_use + 5 KB result \(String(format: "%.1f", Date().timeIntervalSince(t) * 1000)) us/pair")
        t = Date(); for _ in 0..<20 { _ = p.items() }
        print("bench-parse: items() with 1000 calls \(String(format: "%.1f", Date().timeIntervalSince(t) * 1000 / 20)) ms/call")
        exit(0)
    }
}

// `HerdrKitChecks --log-sweep <dir>`: parse every *.jsonl under dir (read-only; last 2 MB like the app) and print counts only.
@MainActor func modeLogSweep() async throws {
    if let i = CommandLine.arguments.firstIndex(of: "--log-sweep"), CommandLine.arguments.count > i + 1 {
        let root = CommandLine.arguments[i + 1]
        let files = (FileManager.default.enumerator(atPath: root)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".jsonl") }
        var totals: [String: Int] = [:], empty = 0, slowest = 0.0, sum = 0.0
        for f in files {
            guard let fh = FileHandle(forReadingAtPath: root + "/" + f) else { continue }
            let size = (try? fh.seekToEnd()) ?? 0
            try? fh.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
            let data = (try? fh.readToEnd()) ?? Data(); try? fh.close()
            var lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            if size > 2_000_000 { lines.removeFirst() }
            let t = Date()
            let items = SessionLog.parse(lines: lines)
            let dt = Date().timeIntervalSince(t) * 1000; sum += dt; slowest = max(slowest, dt)
            if items.isEmpty { empty += 1 }
            for it in items {
                let k: String
                switch it.kind {
                case .userText: k = "user"; case .assistantText: k = "assistant"; case .toolChips(let c): k = "chips"; totals["calls", default: 0] += c.reduce(0) { $0 + $1.calls.count }
                case .permissionRequest: k = "pending"; case .question: k = "question"; case .status: k = "status"
                }
                totals[k, default: 0] += 1
            }
        }
        print("log-sweep: files=\(files.count) empty=\(empty) parse avg \(String(format: "%.1f", sum / Double(max(files.count, 1)))) ms max \(String(format: "%.1f", slowest)) ms")
        print("log-sweep: " + totals.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        exit(0)
    }
}

// `HerdrKitChecks --agents-live [kind…]`: READ-ONLY on the default session (or SESSION=<name>) (snapshot + log file reads, no input).
// For each agent of the given kinds (default pi, cursor): does its log resolve and load, and how many items.
@MainActor func modeAgentsLive() async throws {
    if let i = CommandLine.arguments.firstIndex(of: "--agents-live") {
        let kinds = Set(CommandLine.arguments.dropFirst(i + 1).filter { !$0.hasPrefix("-") }).union(CommandLine.arguments.count > i + 1 ? [] : ["pi", "cursor"])
        let store = HerdrStore(session: ProcessInfo.processInfo.environment["SESSION"].map(HerdrSession.named) ?? HerdrSession.default())
        store.start()
        let t0 = Date()
        while store.workspaces.isEmpty, Date().timeIntervalSince(t0) < 10 { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .seconds(2))   // one session-fallback pass (SessionResolver) for panes without a session
        let panes = store.workspaces.flatMap(\.tabs).flatMap(\.panes).filter { $0.agent.map { kinds.contains($0.kind) } ?? false }
        for p in panes { _ = store.conversation(for: p.agent?.sessionId) }
        try await Task.sleep(for: .seconds(3))
        for p in panes {
            let a = p.agent!, items = store.conversation(for: a.sessionId)
            var by: [String: Int] = [:]
            for it in items {
                switch it.kind {
                case .userText: by["user", default: 0] += 1; case .assistantText: by["assistant", default: 0] += 1
                case .toolChips(let c): by["calls", default: 0] += c.reduce(0) { $0 + $1.calls.count }
                case .permissionRequest: by["pending", default: 0] += 1; case .question: by["question", default: 0] += 1; case .status: by["status", default: 0] += 1
                }
            }
            let sid = a.sessionId.map { $0.hasPrefix("/") ? "path" : "id" } ?? "none"
            print("agents-live: \(p.id) kind=\(a.kind) status=\(a.status.rawValue) session=\(sid) load=\(store.conversationState(for: a.sessionId)) items=\(items.count) "
                  + by.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        print("agents-live: \(panes.count) agents of \(kinds.sorted())")
        exit(0)
    }
}

// `HerdrKitChecks --bench-log <MB>`: first-load time of a synthetic Claude log of that size.
@MainActor func modeBenchLog() async throws {
    if let i = CommandLine.arguments.firstIndex(of: "--bench-log") {
        let mb = CommandLine.arguments.count > i + 1 ? Int(CommandLine.arguments[i + 1]) ?? 38 : 38
        let dir = NSTemporaryDirectory() + "hkbench-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/proj", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/proj/big.jsonl"
        let padding = String(repeating: "x", count: 600)
        var chunk = Data()
        for n in 0..<2000 {
            let l = n % 3 == 0
                ? #"{"type":"user","uuid":"u\#(n)","message":{"role":"user","content":"question \#(n) \#(padding)"}}"#
                : #"{"type":"assistant","uuid":"a\#(n)","message":{"role":"assistant","content":[{"type":"text","text":"answer \#(n) \#(padding)"}]}}"#
            chunk.append(Data((l + "\n").utf8))
        }
        FileManager.default.createFile(atPath: path, contents: nil)
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        while (try fh.offset()) < UInt64(mb) * 1024 * 1024 { try fh.write(contentsOf: chunk) }
        try fh.close()
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        var it = SessionLog(sessionId: "big").snapshots(projectsDir: dir, pollInterval: .milliseconds(20)).makeAsyncIterator()
        let t0 = Date()
        _ = await it.next()                       // initial empty
        let first = await it.next()
        let ms = Date().timeIntervalSince(t0) * 1000
        print("file \(size / 1_048_576) MB, first load \(Int(ms)) ms, items=\(first?.items.count ?? 0)")
        check(ms < 300 && (first?.items.count ?? 0) > 0, "bench: \(mb) MB log first load < 300 ms (\(Int(ms)) ms)")
        exit(failures == 0 ? 0 : 1)
    }
}
