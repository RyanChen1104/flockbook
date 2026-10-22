import Foundation

public enum TerminalEvent: Sendable {
    /// First frame after (re)connect is `full`; later ones are increments (or a full redraw after a resize).
    case frame(TerminalFrame)
    /// Final: the stream ends after this. Reasons seen: `detached`, `terminal attach taken over`,
    /// `terminal attach failed: … already has an attached client …`, `… not found`.
    case closed(reason: String)
    /// The process ended without a closed record; a new one starts after a short delay.
    case reconnecting(attempt: Int)
    /// A line from stderr, e.g. an ignored input.
    case notice(String)
    /// Final: the terminal could not start (no herdr program, or herdr exited 127 before any frame). Why, in words.
    case failed(reason: String)
}

/// One long-lived `herdr terminal session control|observe <terminal_id>` process. Input, resize and frames share its
/// pipes, so a key press is one small pipe write (no socket per key). Control mode owns the terminal's input and size
/// (herdr allows one controller; `takeover` steals it). Observe mode is read-only.
public final class TerminalSession: @unchecked Sendable {
    public enum Mode: Sendable, Equatable { case observe, control(takeover: Bool) }

    public let terminalId: String
    public let mode: Mode
    /// Frames and state changes. Finishes after `closed`, `release()` or `stop()`.
    public let events: AsyncStream<TerminalEvent>

    private let cont: AsyncStream<TerminalEvent>.Continuation
    /// The program and its first arguments; nil: herdr's, found when each process starts (`find`).
    private let launcher: [String]?
    private let cliPrefix: [String]
    private let find: @Sendable () -> String?
    private let stripHerdrEnv: Bool
    private let lock = NSLock()
    private var proc: Process?
    private var stdin: FileHandle?
    private var started = false
    private var stopped = false
    private var wantCols: Int?
    private var wantRows: Int?
    private var lastSize: (cols: Int, rows: Int)?
    private var showed = false        // a frame came in some run: from then on a missing herdr is a moment (an upgrade), not final
    private var bracketed = true      // herdr frames do not carry DEC private modes (see README); assume yes until a frame says ?2004l

    /// `launcher` replaces `<herdr> --session <name>` (tests use a fake script). `find` gives herdr's full path.
    public init(terminalId: String, session: HerdrSession, mode: Mode = .control(takeover: false),
                cols: Int? = nil, rows: Int? = nil, launcher: [String]? = nil, find: @escaping @Sendable () -> String? = { ConnectionCheck.findHerdr() }) {
        self.terminalId = terminalId
        self.mode = mode
        self.launcher = launcher
        self.cliPrefix = session.cliPrefix
        self.find = find
        self.stripHerdrEnv = session.name != nil
        self.wantCols = cols.flatMap { $0 > 0 ? $0 : nil }
        self.wantRows = rows.flatMap { $0 > 0 ? $0 : nil }
        (events, cont) = AsyncStream.makeStream(of: TerminalEvent.self, bufferingPolicy: .unbounded)
        signal(SIGPIPE, SIG_IGN)
        cont.onTermination = { [weak self] _ in self?.stop() }
    }

    deinit { stop() }

    /// Current pty size as last reported by herdr (nil before the first frame).
    public var size: (cols: Int, rows: Int)? { lock.withLock { lastSize } }
    /// Whether `paste` wraps the text in bracketed-paste markers. herdr's frames normally do not show the program's mode, so
    /// this stays true unless a frame carries `ESC[?2004l` (then false until `ESC[?2004h`). Override with `paste(_:bracketed:)`.
    public var bracketedPaste: Bool { lock.withLock { bracketed } }

    /// herdr's full path and the session's arguments; nil when there is no herdr program.
    static func launcher(session: HerdrSession, environment: [String: String], home: String) -> [String]? {
        ConnectionCheck.findHerdr(environment: environment, home: home).map { [$0] + session.cliPrefix }
    }
    /// `PATH` for the herdr process: the app's, then the usual install folders it lacks.
    static func childPath(environment: [String: String], home: String) -> String {
        let have = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (have + ConnectionCheck.usualFolders(home: home).filter { !have.contains($0) }).joined(separator: ":")
    }

    public func start() {
        let go = lock.withLock { () -> Bool in defer { started = true }; return !started && !stopped }
        guard go else { return }
        Task.detached { [self] in
            let attempt = Locked(0)
            while !lock.withLock({ stopped }) {
                let outcome = await runOnce(onFrame: { attempt.set(0) })
                if outcome == .final || lock.withLock({ stopped }) { break }
                let n = attempt.update { $0 += 1; return $0 }
                cont.yield(.reconnecting(attempt: n))
                try? await Task.sleep(for: .milliseconds(min(2000, 250 << min(n - 1, 3))))
            }
            cont.finish()
        }
    }

    // MARK: input (control mode)

    /// Raw bytes to the program: text, control keys, escape sequences, any UTF-8. False when not connected or observing.
    @discardableResult
    public func send(bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        return writeJSON(["type": "terminal.input", "bytes": Data(bytes).base64EncodedString()])
    }

    @discardableResult
    public func send(text: String) -> Bool { send(bytes: Array(text.utf8)) }

    /// Pastes text. Wrapped in bracketed paste (default: `bracketedPaste`); otherwise newlines become CR.
    @discardableResult
    public func paste(_ text: String, bracketed: Bool? = nil) -> Bool {
        guard mode != .observe else { return false }
        if bracketed ?? bracketedPaste { return send(text: "\u{1b}[200~" + text + "\u{1b}[201~") }
        return send(text: text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r"))
    }

    /// Resizes the pty (control mode). Kept for reconnects. Ignores values below 1.
    public func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        lock.withLock { wantCols = cols; wantRows = rows }
        writeJSON(["type": "terminal.resize", "cols": cols, "rows": rows])
    }

    public func scroll(lines: Int, up: Bool) { wheel(lines: lines, up: up) }

    /// One wheel step for the terminal, control mode only (observe returns false and sends nothing). herdr decides where it goes
    /// from the program's current mode, so the app must not turn it into keys itself:
    /// - program tracks the mouse (`?1000`/`?1002`/`?1003`, SGR or legacy encoding): one wheel event (button 64 up / 65 down,
    ///   position 1;1) reaches the program;
    /// - alternate screen with alternate scroll (`?1007`): one Up/Down arrow;
    /// - alternate screen with neither: nothing;
    /// - main screen: herdr scrolls its own history by `lines` (shared pane position, see `HerdrClient.setScrollOffset`).
    /// A forwarded step is **one event per call**, whatever `lines` is. For a program, pass `eventPerLine: true` to send
    /// `lines` separate steps. The position cannot be chosen (herdr always uses 1;1).
    @discardableResult
    public func wheel(lines: Int, up: Bool, eventPerLine: Bool = false) -> Bool {
        guard mode != .observe, lines > 0 else { return false }
        let dir = up ? "up" : "down"
        if eventPerLine {
            var ok = true
            for _ in 0..<lines { ok = writeJSON(["type": "terminal.scroll", "lines": 1, "direction": dir]) && ok }
            return ok
        }
        return writeJSON(["type": "terminal.scroll", "lines": lines, "direction": dir])
    }

    public enum MouseEncoding: Sendable { case sgr, legacy }

    /// Right click (press and release) at a cell, 1-based `col`/`row` of the terminal grid. Control mode only. herdr 0.9.1 has no
    /// `terminal.mouse`, so this sends the xterm mouse bytes as plain input: `ESC[<2;col;rowM` + `ESC[<2;col;rowm` (SGR, `?1006`)
    /// or `ESC[M` + 3 bytes (legacy, `?1000` only; col and row must be <= 223). The app cannot read the program's mouse mode, so the
    /// caller chooses: a program that did not enable mouse tracking will print these bytes as text. Use it only when the user
    /// turned "Send right-clicks to pane" on. Returns false in observe mode or for an invalid cell.
    @discardableResult
    public func rightClick(col: Int, row: Int, encoding: MouseEncoding = .sgr) -> Bool {
        guard mode != .observe, col >= 1, row >= 1 else { return false }
        switch encoding {
        case .sgr:
            return send(text: "\u{1b}[<2;\(col);\(row)M\u{1b}[<2;\(col);\(row)m")
        case .legacy:
            guard col <= 223, row <= 223 else { return false }
            let c = UInt8(32 + col), r = UInt8(32 + row)
            return send(bytes: [0x1b, 0x5b, 0x4d, 34, c, r, 0x1b, 0x5b, 0x4d, 35, c, r])
        }
    }

    /// Gives the input back (the pty returns to the other client's size) and ends the stream.
    public func release() {
        lock.withLock { stopped = true }
        writeJSON(["type": "terminal.release"])
        // the process answers closed(detached) and exits; stop() is the fallback if it does not
        Task.detached { [self] in try? await Task.sleep(for: .seconds(2)); stop() }
    }

    /// Ends the session without telling herdr (the process is terminated).
    public func stop() {
        let p = lock.withLock { () -> Process? in stopped = true; defer { proc = nil; stdin = nil }; return proc }
        if let p, p.isRunning { p.terminate() }
        cont.finish()
    }

    var processIdentifier: Int32? { lock.withLock { proc?.processIdentifier } }

    func sendRaw(_ line: String) { _ = write(Data((line + "\n").utf8)) }

    @discardableResult
    private func writeJSON(_ o: [String: Any]) -> Bool {
        guard mode != .observe, let d = try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]) else { return false }
        return write(d + Data([0x0A]))
    }

    private func write(_ d: Data) -> Bool {
        guard let h = lock.withLock({ stdin }) else { return false }
        return (try? h.write(contentsOf: d)) != nil
    }

    // MARK: process

    private enum Outcome { case final, retry }

    private func runOnce(onFrame: @escaping @Sendable () -> Void) async -> Outcome {
        let (cols, rows) = lock.withLock { () -> (Int?, Int?) in (wantCols, wantRows) }
        guard let argvPrefix = launcher ?? find().map({ [$0] + cliPrefix }) else {
            if lock.withLock({ showed }) { cont.yield(.notice(ConnectionCheck.notFound)); return .retry }
            cont.yield(.failed(reason: ConnectionCheck.notFound))
            return .final
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argvPrefix[0])
        var args = Array(argvPrefix.dropFirst())
        args += ["terminal", "session", mode == .observe ? "observe" : "control", terminalId]
        if case .control(let takeover) = mode, takeover { args.append("--takeover") }
        if let cols { args += ["--cols", String(cols)] }
        if let rows { args += ["--rows", String(rows)] }
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        if stripHerdrEnv { for k in env.keys where k.hasPrefix("HERDR_") { env[k] = nil } }
        env["PATH"] = Self.childPath(environment: env, home: NSHomeDirectory())
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp

        let finalReason = Locked<String?>(nil)
        // Exit 127 before any frame: the program is not there (`env: herdr: …`) or cannot run. Final, with its last words.
        let framed = Locked(false), lastErr = Locked<String?>(nil), status = Locked<Int32>(0)
        let outReader = LineAccumulator { [self] line in
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            switch o["type"] as? String {
            case "terminal.frame":
                let bytes = Data(base64Encoded: o["bytes"] as? String ?? "") ?? Data()
                let f = TerminalFrame(seq: o["seq"] as? Int ?? 0, full: o["full"] as? Bool ?? false,
                                      width: o["width"] as? Int ?? 0, height: o["height"] as? Int ?? 0, bytes: bytes)
                lock.withLock {
                    if f.width > 0, f.height > 0 { lastSize = (f.width, f.height) }
                    if let on = bytes.range(of: Data("\u{1b}[?2004h".utf8), options: .backwards),
                       bytes.range(of: Data("\u{1b}[?2004l".utf8), options: .backwards).map({ $0.lowerBound < on.lowerBound }) ?? true {
                        bracketed = true
                    } else if bytes.range(of: Data("\u{1b}[?2004l".utf8)) != nil { bracketed = false }
                }
                framed.set(true)
                lock.withLock { showed = true }
                onFrame()
                cont.yield(.frame(f))
            case "terminal.closed":
                let r = o["reason"] as? String ?? ""
                finalReason.set(r)
                cont.yield(.closed(reason: r))
            default: break
            }
        }
        let errReader = LineAccumulator { [cont] line in
            if let s = String(data: line, encoding: .utf8), !s.isEmpty { lastErr.set(s); cont.yield(.notice(s)) }
        }
        // three things must finish: stdout EOF, stderr EOF (herdr's last words are all read) and process exit
        return await withCheckedContinuation { (k: CheckedContinuation<Outcome, Never>) in
            let pending = Locked(3)
            let done: @Sendable () -> Void = { [self] in
                guard pending.update({ $0 -= 1; return $0 }) == 0 else { return }
                lock.withLock { proc = nil; stdin = nil }
                if finalReason.get() == nil, status.get() == 127, !framed.get(), !lock.withLock({ showed }) {
                    let why = lastErr.get() ?? "herdr could not start (exit 127)."
                    finalReason.set(why)
                    cont.yield(.failed(reason: why))
                }
                k.resume(returning: finalReason.get() != nil ? .final : .retry)
            }
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; done(); return }
                outReader.feed(d)
            }
            // stderr ends once: at EOF, or a second after exit when a child of herdr still holds it open
            let errEnded = Locked(false)
            let endErr: @Sendable () -> Void = {
                guard errEnded.update({ let was = $0; $0 = true; return !was }) else { return }
                errReader.feed(Data([0x0A]))   // a last line without newline too
                done()
            }
            err.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; endErr(); return }
                errEnded.update { ended in if !ended { errReader.feed(d) } }
            }
            p.terminationHandler = { p in
                status.set(p.terminationStatus)
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    guard !errEnded.get() else { return }
                    err.fileHandleForReading.readabilityHandler = nil
                    endErr()
                    try? err.fileHandleForReading.close()
                }
                done()
            }
            do {
                lock.withLock { proc = p; stdin = inp.fileHandleForWriting }
                try p.run()
                if lock.withLock({ stopped }) && mode != .observe { /* release() may race the start; the process sees EOF */ }
            } catch {
                lock.withLock { proc = nil; stdin = nil }
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                cont.yield(.failed(reason: "cannot start herdr: \(error.localizedDescription)"))
                finalReason.set("start failed")
                k.resume(returning: .final)
            }
        }
    }
}

final class Locked<T>: @unchecked Sendable {
    private let l = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    func get() -> T { l.withLock { v } }
    func set(_ x: T) { l.withLock { v = x } }
    func update<R>(_ f: (inout T) -> R) -> R { l.withLock { f(&v) } }
}
