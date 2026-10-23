import Foundation

// A herdr on another machine, reached through the owner's own OpenSSH. Flockbook stores only the SSH destination and the
// herdr session name: keys, passwords and host keys stay with OpenSSH (ssh-agent, ~/.ssh/config, known_hosts).
//
// Everything the app does on the host is one POSIX `sh` command line run by `RemoteHost.process(_:)`:
// - the herdr API: `herdr --session S remote-api-bridge` joins stdio to the host's API socket (`RemoteBridge` puts a local
//   socket in front of it, so `HerdrClient` is unchanged);
// - terminals: `herdr terminal session control …` over the same stdio protocol as the local program;
// - files: agent logs, pictures, uploads, hook records (`RemoteFiles`).
// `Via.local` runs the same command lines with /bin/sh on this Mac: checks use it, no host needed.

/// Where herdr runs when it is not this Mac's own socket.
public struct RemoteHost: Sendable, Hashable {
    public enum Via: Sendable, Hashable {
        /// `ssh <destination>`: `user@host`, `host` or a `Host` alias from ~/.ssh/config.
        case ssh(destination: String)
        /// /bin/sh on this Mac. For checks: the same command lines without a second machine.
        case local
    }
    public let via: Via

    public init(via: Via) { self.via = via }

    public static func ssh(_ destination: String) throws -> RemoteHost {
        if let why = destinationProblem(destination) { throw HerdrError.protocolError(why) }
        return RemoteHost(via: .ssh(destination: destination))
    }

    /// For labels: the destination, or "this Mac (checks)".
    public var label: String {
        switch via {
        case .ssh(let d): d
        case .local: "this Mac (checks)"
        }
    }

    /// Why `s` is not a destination Flockbook passes to ssh; nil: fine. Rejects what ssh could read as an option
    /// (a leading "-", e.g. `-oProxyCommand=…`), white space, control characters and shell or path characters.
    public static func destinationProblem(_ s: String) -> String? {
        if s.isEmpty { return "Enter an SSH destination, such as user@host." }
        if s.utf8.count > 255 { return "The SSH destination is too long." }
        if s.hasPrefix("-") { return "An SSH destination cannot start with “-”." }
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_@:[]%")
        if !s.unicodeScalars.allSatisfy(ok.contains) {
            return "Use only letters, digits and . - _ @ : [ ] % in the SSH destination (user@host or a Host alias)."
        }
        return nil
    }

    // MARK: - Command lines

    /// `s` in single quotes for /bin/sh (always quoted: safe for any bytes but NUL).
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// A command line that runs `argv` as is: every word quoted.
    public static func commandLine(_ argv: [String]) -> String { argv.map(quote).joined(separator: " ") }

    /// Stderr marker of `herdrCommand` when the host has no herdr program (exit 127).
    public static let herdrMissingMarker = "flockbook: herdr not found on the host"

    /// Finds herdr on the host (a non-interactive SSH shell often has a short PATH) and execs it with
    /// `--session <session>` (when named) and `args`. Exit 127 with `herdrMissingMarker` when there is none.
    public static func herdrCommand(session: String?, _ args: [String]) -> String {
        let candidates = ["\"$HOME/.local/bin/herdr\"", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr", "\"$HOME/.cargo/bin/herdr\"",
                          "/home/linuxbrew/.linuxbrew/bin/herdr", "\"$HOME/.nix-profile/bin/herdr\"", "/run/current-system/sw/bin/herdr",
                          "\"$HOME/.local/share/mise/shims/herdr\""]
        let argv = (session.map { ["--session", $0] } ?? []) + args
        return "h=$(command -v herdr 2>/dev/null) || h=; "
            + "for p in \(candidates.joined(separator: " ")); do [ -n \"$h\" ] && break; [ -x \"$p\" ] && h=$p; done; "
            + "[ -n \"$h\" ] || { echo \(quote(herdrMissingMarker)) >&2; exit 127; }; "
            + "exec \"$h\" \(commandLine(argv))"
    }

    // MARK: - Processes

    /// Private folder for the relay sockets and ssh's control sockets: short (a Unix socket path has 104 bytes), mode 700.
    public static var runtimeDir: String { "/tmp/flockbook-\(getuid())" }

    /// Makes `runtimeDir` (mode 700) and refuses one that is not ours or that others may open.
    public static func ensureRuntimeDir() throws -> String {
        let d = runtimeDir
        if mkdir(d, 0o700) != 0 && errno != EEXIST { throw HerdrError.socket("cannot make \(d): \(String(cString: strerror(errno)))") }
        var st = stat()
        guard lstat(d, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
            throw HerdrError.socket("\(d) is not a folder of this user")
        }
        if st.st_mode & 0o077 != 0 { chmod(d, 0o700) }
        return d
    }

    /// ssh's options. BatchMode: never a password or passphrase prompt (load keys with ssh-add). StrictHostKeyChecking:
    /// an unknown or changed host key fails (the owner runs `ssh <destination>` once in a terminal to accept it). One
    /// shared connection per host (ControlMaster). No agent, X11 or port forwarding, whatever ~/.ssh/config says.
    public static func sshOptions(controlDir: String) -> [String] {
        ["-T",
         "-o", "BatchMode=yes",
         "-o", "StrictHostKeyChecking=yes",
         "-o", "ConnectTimeout=10",
         "-o", "ServerAliveInterval=15",
         "-o", "ServerAliveCountMax=3",
         "-o", "ControlMaster=auto",
         "-o", "ControlPath=\(controlDir)/cm-%C",
         "-o", "ControlPersist=600",
         "-o", "ForwardAgent=no",
         "-o", "ForwardX11=no",
         "-o", "ClearAllForwardings=yes",
         "-o", "PermitLocalCommand=no"]
    }

    /// `command` as the one word sshd hands to the host user's login shell (`$SHELL -c`), which may be csh, tcsh, zsh
    /// or fish: `exec /bin/sh -c '…'`, so the POSIX command line always runs in sh. The word is one line, has no "!",
    /// and inside its quotes no backslash comes before a quote or a backslash (csh refuses a newline in quotes and
    /// expands "!" even there; fish reads `\\` and `\'` as escapes). So newline, backslash, quote and "!" travel as
    /// bytes 1 to 4, and `tr` turns them back before sh evals the command. Command lines here never hold bytes 1 to 4
    /// (they would come back as those four), so a word is never wrapped twice.
    public static func loginShellWord(_ command: String) -> String {
        let coded = command.replacingOccurrences(of: "\n", with: "\u{1}").replacingOccurrences(of: "\\", with: "\u{2}")
            .replacingOccurrences(of: "'", with: "\u{3}").replacingOccurrences(of: "!", with: "\u{4}")
        return "exec /bin/sh -c " + quote("eval \"$(printf '%s' '\(coded)' | tr '\\001\\002\\003\\004' '\\012\\134\\047\\041')\"")
    }

    /// The program and arguments that run `command` on the host.
    public func argv(_ command: String, controlDir: String = RemoteHost.runtimeDir) -> [String] {
        switch via {
        case .ssh(let d): ["/usr/bin/ssh"] + Self.sshOptions(controlDir: controlDir) + ["--", d, Self.loginShellWord(command)]
        case .local: ["/bin/sh", "-c", Self.loginShellWord(command)]   // the same word, so checks run it too
        }
    }

    /// A process that runs `command` on the host; the caller sets its pipes and runs it. `HERDR_*` variables are left out
    /// (they would point a local herdr at the pane the app runs in).
    public func process(_ command: String) throws -> Process {
        let dir = try Self.ensureRuntimeDir()
        let a = argv(command, controlDir: dir)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: a[0])
        p.arguments = Array(a.dropFirst())
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("HERDR_") { env[k] = nil }
        p.environment = env
        return p
    }

    public struct Result: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: String
        public var ok: Bool { status == 0 }
    }

    /// Runs `command` on the host to the end. `input` goes to its stdin (then EOF). Over `timeout` the process is killed
    /// and the result has status -1.
    public func run(_ command: String, input: Data? = nil, timeout: Duration = .seconds(30)) async throws -> Result {
        let p = try process(command)
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        let outData = Locked(Data()), errData = Locked(Data())
        let group = DispatchGroup()
        for (pipe, box) in [(out, outData), (err, errData)] {
            group.enter()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; group.leave() } else { box.update { $0.append(d) } }
            }
        }
        signal(SIGPIPE, SIG_IGN)
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        try p.run()
        let killed = Locked(false)
        // The timer runs from the start: a command that does not read its stdin cannot hold `run` past `timeout`.
        let killer = Task.detached {
            try? await Task.sleep(for: timeout)
            guard p.isRunning else { return }
            killed.set(true); p.terminate()
            try? await Task.sleep(for: .seconds(2))
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        let w = inp.fileHandleForWriting
        DispatchQueue.global().async {
            if let input, !input.isEmpty { try? w.write(contentsOf: input) }   // EPIPE once the command is gone
            try? w.close()
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                exited.wait()
                // After a kill, a child the command left behind may keep the output pipes open: do not wait for it.
                if killed.get() { _ = group.wait(timeout: .now() + 1) } else { group.wait() }
                c.resume()
            }
        }
        killer.cancel()
        return Result(status: killed.get() ? -1 : p.terminationStatus, stdout: outData.get(),
                      stderr: String(decoding: errData.get(), as: UTF8.self))
    }
}
