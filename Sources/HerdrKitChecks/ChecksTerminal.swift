import Foundation
@testable import HerdrKit

// Terminal session, scrollback, file watcher, store timing (fake herdr, no server needed).

// TerminalSession against a fake `terminal session control` (no herdr needed)
@MainActor func checksTerminalSession() async throws {
    do {
        final class EBox: @unchecked Sendable { let l = NSLock(); var v: [TerminalEvent] = []
            func add(_ x: TerminalEvent) { l.withLock { v.append(x) } }
            var all: [TerminalEvent] { l.withLock { v } }
            var frames: [TerminalFrame] { all.compactMap { if case .frame(let f) = $0 { return f } else { return nil } } } }
        func until(_ sec: Double, _ ok: () -> Bool) async -> Bool {
            let t = Date()
            while Date().timeIntervalSince(t) < sec { if ok() { return true }; try? await Task.sleep(nanoseconds: 10_000_000) }
            return ok()
        }
        let dir = NSTemporaryDirectory() + "hk-term-\(getpid())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let log = dir + "/log.txt", script = dir + "/fake.sh"
        // Prints a full frame first. resize -> new full frame. "crash" -> exit 1. release -> closed(detached).
        // FAKE_MODE=takeover prints a closed(taken over) and exits.
        try """
        #!/bin/sh
        echo "ARGS $@" >> "$FAKE_LOG"
        if [ "$FAKE_MODE" = takeover ]; then echo '{"type":"terminal.closed","reason":"terminal attach taken over"}'; exit 0; fi
        printf '{"type":"terminal.frame","seq":1,"full":true,"encoding":"ansi","width":80,"height":24,"bytes":"%s"}\n' "$(printf '\\033[?2004hhello' | base64)"
        while IFS= read -r line; do
          echo "$line" >> "$FAKE_LOG"
          case "$line" in
            *terminal.resize*) printf '{"type":"terminal.frame","seq":2,"full":true,"width":100,"height":30,"bytes":"%s"}\n' "$(printf '\\033[?2004l' | base64)" ;;
            *crash*) exit 1 ;;
            *release*) printf '{"type":"terminal.closed","reason":"detached"}\n'; exit 0 ;;
          esac
        done
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        setenv("FAKE_LOG", log, 1)
        func logText() -> String { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }

        let ts = TerminalSession(terminalId: "term_x", session: .default(), mode: .control(takeover: false), launcher: [script])
        let box = EBox()
        let reader = Task { for await e in ts.events { box.add(e) } }
        ts.start()
        check(await until(3) { box.frames.first?.full == true && box.frames.first?.width == 80 }, "term: first frame is full, 80 wide")
        check(ts.size?.cols == 80 && ts.size?.rows == 24, "term: size from the frame")
        check(ts.bracketedPaste, "term: bracketed paste on by default / after ?2004h")
        check(logText().contains("ARGS terminal session control term_x"), "term: control args")

        let bytes: [UInt8] = [0x1b, 0x5b, 0x41, 0x03, 0xff, 0xe4, 0xbd, 0xa0]
        ts.send(bytes: bytes)
        check(await until(2) { logText().contains(Data(bytes).base64EncodedString()) }, "term: arbitrary bytes sent as base64 terminal.input")
        ts.send(text: "你好")
        check(await until(2) { logText().contains(Data("你好".utf8).base64EncodedString()) }, "term: UTF-8 text sent")
        ts.paste("a\nb")
        check(await until(2) { logText().contains(Data("\u{1b}[200~a\nb\u{1b}[201~".utf8).base64EncodedString()) }, "term: paste wrapped in bracketed paste")

        ts.resize(cols: 100, rows: 30)
        check(await until(2) { logText().contains(#""cols":100"#) && logText().contains(#""rows":30"#) }, "term: resize sent")
        check(await until(2) { ts.size?.cols == 100 && ts.size?.rows == 30 }, "term: size follows the resize frame")
        check(!ts.bracketedPaste, "term: ?2004l in a frame turns bracketed paste off")
        ts.resize(cols: 0, rows: 30)
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(!logText().contains(#""cols":0"#), "term: resize with 0 is ignored")

        ts.rightClick(col: 10, row: 5)
        check(await until(2) { logText().contains(Data("\u{1b}[<2;10;5M\u{1b}[<2;10;5m".utf8).base64EncodedString()) }, "term: right click as SGR press+release at col,row")
        ts.rightClick(col: 3, row: 4, encoding: .legacy)
        check(await until(2) { logText().contains(Data([0x1b, 0x5b, 0x4d, 34, 35, 36, 0x1b, 0x5b, 0x4d, 35, 35, 36]).base64EncodedString()) }, "term: right click legacy (X10) encoding")
        check(!ts.rightClick(col: 0, row: 4), "term: right click with col 0 is ignored")
        ts.wheel(lines: 3, up: true)
        check(await until(2) { logText().contains(#""type":"terminal.scroll""#) && logText().contains(#""lines":3"#) && logText().contains(#""direction":"up""#) }, "term: wheel sends terminal.scroll")
        ts.wheel(lines: 2, up: false, eventPerLine: true)
        check(await until(2) { logText().components(separatedBy: #""direction":"down""#).count - 1 == 2 && logText().contains(#""lines":1"#) }, "term: wheel eventPerLine sends one scroll per line")
        check(!ts.wheel(lines: 0, up: true), "term: wheel(0) sends nothing")

        let spawns0 = logText().components(separatedBy: "ARGS ").count - 1
        ts.sendRaw(#"{"type":"crash"}"#)
        check(await until(5) { box.all.contains { if case .reconnecting = $0 { return true } else { return false } } && box.frames.count >= 3 }, "term: reconnects after the process dies, new full frame")
        let t2 = logText()
        check(t2.components(separatedBy: "ARGS ").count - 1 == spawns0 + 1 && t2.contains("--cols 100 --rows 30"), "term: reconnect keeps the last size")

        ts.release()
        check(await until(3) { box.all.contains { if case .closed(let r) = $0 { return r == "detached" } else { return false } } }, "term: release -> closed(detached)")
        try? await Task.sleep(nanoseconds: 800_000_000)
        check(logText().components(separatedBy: "ARGS ").count - 1 == spawns0 + 1, "term: no reconnect after release")
        reader.cancel()

        setenv("FAKE_MODE", "takeover", 1)
        try? FileManager.default.removeItem(atPath: log)
        let ts2 = TerminalSession(terminalId: "term_y", session: .default(), mode: .control(takeover: false), launcher: [script])
        let box2 = EBox()
        let reader2 = Task { for await e in ts2.events { box2.add(e) } }
        ts2.start()
        check(await until(3) { box2.all.contains { if case .closed(let r) = $0 { return r.contains("taken over") } else { return false } } }, "term: taken over is reported")
        try? await Task.sleep(nanoseconds: 800_000_000)
        check(logText().components(separatedBy: "ARGS ").count - 1 == 1, "term: no reconnect after taken over")
        unsetenv("FAKE_MODE")
        reader2.cancel()

        let plain = TerminalSession(terminalId: "term_z", session: .default(), mode: .observe, launcher: [script])
        check(plain.rightClick(col: 1, row: 1) == false && plain.wheel(lines: 1, up: true) == false && plain.paste("a\nb") == false, "term: observe mode cannot send")
    }
}

// Scroll info and scrollback parsing (fixtures from herdr 0.9.1 responses)
@MainActor func checksScroll() async throws {
    do {
        let paneShell = Data(#"{"id":"x","result":{"type":"pane_info","pane":{"pane_id":"w4:p1","scroll":{"max_offset_from_bottom":363,"offset_from_bottom":12,"viewport_rows":40}}}}"#.utf8)
        let paneFlat = Data(#"{"id":"x","result":{"type":"pane_info","pane":{"pane_id":"w4:p1","scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":40}}}}"#.utf8)
        let procShell = Data(#"{"id":"x","result":{"type":"pane_process_info","process_info":{"foreground_process_group_id":5303,"foreground_processes":[{"name":"zsh","pid":5303}],"shell_pid":5303}}}"#.utf8)
        let procLess = Data(#"{"id":"x","result":{"type":"pane_process_info","process_info":{"foreground_process_group_id":20415,"foreground_processes":[{"name":"less","pid":20415}],"shell_pid":5303}}}"#.utf8)
        let a = try ScrollInfo.parse(pane: paneShell, process: procShell)
        check(a.maxOffsetFromBottom == 363 && a.offsetFromBottom == 12 && a.viewportRows == 40, "scrollInfo: offsets")
        check(a.kind == .history && a.shellIsForeground == true && a.foregroundName == "zsh", "scrollInfo: shell with history -> .history")
        let b = try ScrollInfo.parse(pane: paneFlat, process: procLess)
        check(b.kind == .fullScreenProgram && b.foregroundName == "less", "scrollInfo: no history + other program -> .fullScreenProgram")
        let c = try ScrollInfo.parse(pane: paneFlat, process: procShell)
        check(c.kind == .none, "scrollInfo: fresh shell -> .none")
        let d = try ScrollInfo.parse(pane: paneFlat, process: nil)
        check(d.kind == .none && d.shellIsForeground == nil, "scrollInfo: unknown process -> .none")
        let readOK = Data(#"{"id":"x","result":{"type":"pane_read","read":{"pane_id":"w4:p1","source":"recent","format":"ansi","text":"a\r\nb\r\n","revision":3,"truncated":true}}}"#.utf8)
        let sb = try Scrollback.parse(readOK)
        check(sb.text == "a\r\nb\r\n" && sb.truncated && sb.lineCount == 2 && sb.revision == 3, "scrollback: parse")
    }
}

// File watcher (DispatchSource) and staged first load. The safety-net timer is 30 s, so only the watcher can be fast.
@MainActor func checksFileWatcher() async throws {
    do {
        final class Box: @unchecked Sendable { let l = NSLock(); var v: [[ConversationItem]] = []
            func add(_ x: [ConversationItem]) { l.withLock { v.append(x) } }
            var all: [[ConversationItem]] { l.withLock { v } } }
        func line(_ n: Int, pad: Int = 0) -> String {
            #"{"type":"user","uuid":"w\#(n)","message":{"content":"msg \#(n) \#(String(repeating: "x", count: pad))"}}"# + "\n"
        }
        func waitFor(_ box: Box, _ sec: Double, _ ok: ([[ConversationItem]]) -> Bool) async -> Bool {
            let t = Date()
            while Date().timeIntervalSince(t) < sec { if ok(box.all) { return true }; try? await Task.sleep(nanoseconds: 10_000_000) }
            return ok(box.all)
        }
        let root = NSTemporaryDirectory() + "hk-watch-\(getpid())"
        try FileManager.default.createDirectory(atPath: root + "/p", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/p/w1.jsonl"
        try (line(1) + line(2)).write(toFile: path, atomically: true, encoding: .utf8)
        let box = Box()
        let stream = SessionLog(sessionId: "w1").items(projectsDir: root, pollInterval: .seconds(30))
        let reader = Task { for await x in stream { box.add(x) } }
        check(await waitFor(box, 3) { $0.last?.count == 2 }, "watch: first load")
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try fh.seekToEnd(); try fh.write(contentsOf: Data(line(3).utf8)); try fh.close()
        check(await waitFor(box, 2) { $0.last?.count == 3 }, "watch: append seen within 2 s without polling")
        try FileManager.default.removeItem(atPath: path)
        try (line(7)).write(toFile: path, atomically: true, encoding: .utf8)
        check(await waitFor(box, 3) { $0.last?.count == 1 }, "watch: replaced file is reopened")
        let fh2 = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try fh2.seekToEnd(); try fh2.write(contentsOf: Data(line(8).utf8)); try fh2.close()
        check(await waitFor(box, 2) { $0.last?.count == 2 }, "watch: append after replace seen")
        reader.cancel()

        // staged load: 256 KB first, then the rest of the 2 MB tail; ids stay put
        let big = root + "/p/w2.jsonl"
        var text = ""
        for n in 0..<1500 { text += line(n, pad: 1000) }          // ~1.6 MB
        try text.write(toFile: big, atomically: true, encoding: .utf8)
        let box2 = Box()
        let stream2 = SessionLog(sessionId: "w2").items(projectsDir: root, pollInterval: .seconds(30))
        let reader2 = Task { for await x in stream2 { box2.add(x) } }
        check(await waitFor(box2, 5) { $0.last?.count == 1500 }, "stage: backfill reaches the full file")
        let counts = box2.all.map(\.count).filter { $0 > 0 }
        check(counts.count >= 2 && counts.first! < 400 && counts == counts.sorted(), "stage: short view first (\(counts.first ?? 0) items), then longer")
        let firstIds = box2.all.first { !$0.isEmpty }!.map(\.id), lastIds = box2.all.last!.map(\.id)
        check(Array(lastIds.suffix(firstIds.count)) == firstIds, "stage: ids stable across the backfill")
        // depth switching: down drops the front items, up loads them again; short mode never backfills
        let log2 = SessionLog(sessionId: "w2")
        let box3 = Box()
        let stream3 = log2.items(projectsDir: root, pollInterval: .seconds(30))
        let reader3 = Task { for await x in stream3 { box3.add(x) } }
        check(await waitFor(box3, 5) { $0.last?.count == 1500 }, "depth: full by default")
        log2.setFull(false)
        check(await waitFor(box3, 3) { ($0.last?.count ?? 0) > 0 && ($0.last?.count ?? 9999) < 400 }, "depth: setFull(false) trims to the short tail (\(box3.all.last?.count ?? 0))")
        check(box3.all.last?.last?.id == lastIds.last, "depth: newest item kept")
        log2.setFull(true)
        check(await waitFor(box3, 3) { $0.last?.count == 1500 }, "depth: setFull(true) restores the 2 MB tail")
        reader3.cancel()
        let short = SessionLog(sessionId: "w2")
        short.setFull(false)
        let box4 = Box()
        let stream4 = short.items(projectsDir: root, pollInterval: .seconds(30))
        let reader4 = Task { for await x in stream4 { box4.add(x) } }
        _ = await waitFor(box4, 1.5) { _ in false }
        check((box4.all.last?.count ?? 0) > 0 && (box4.all.last?.count ?? 9999) < 400, "depth: short mode stays short (\(box4.all.last?.count ?? 0))")
        reader4.cancel()
        reader2.cancel()
    }
}

// Store timing against a fake herdr socket: one event reaches the store fast, a restart is picked up within ~1 s.
@MainActor func checksStoreTiming() async throws {
    do {
        func waitMS(_ sec: Double, _ ok: () -> Bool) async -> Double? {
            let t = Date(); while Date().timeIntervalSince(t) < sec { if ok() { return Date().timeIntervalSince(t) * 1000 }; try? await Task.sleep(nanoseconds: 2_000_000) }; return nil
        }
        let fake = FakeHerdr(path: NSTemporaryDirectory() + "hkfk-\(getpid()).sock")
        try fake.start()
        let st = HerdrStore(session: HerdrSession(name: "fake", socketPath: fake.path))
        st.start()
        _ = await waitMS(3) { st.workspaces.first?.label == "v0" }
        try? await Task.sleep(nanoseconds: 300_000_000)
        fake.label = "e1"; fake.pushEvent()
        let lat = await waitMS(2) { st.workspaces.first?.label == "e1" }
        check((lat ?? 9999) < 100, "store: event -> workspaces < 100 ms (\(Int(lat ?? -1)) ms)")
        fake.kill()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        fake.label = "r1"; try fake.start()
        let back = await waitMS(3) { st.connected && st.workspaces.first?.label == "r1" }
        check((back ?? 9999) < 1500, "store: back within 1.5 s after a 2.5 s socket loss (\(Int(back ?? -1)) ms)")
        st.stop(); fake.kill()
    }
}
