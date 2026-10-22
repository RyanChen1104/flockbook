import Foundation

/// Why the app cannot reach herdr, with the next step the user can take. Nil from `ConnectionCheck.diagnose`: connected.
public enum ConnectionProblem: Sendable, Hashable {
    /// No herdr server and no `herdr` program: install herdr.
    case herdrMissing
    /// herdr is installed but its server for this session is not running (no socket, or a socket nobody listens on).
    /// `command` starts it in a terminal.
    case notRunning(command: String)
    /// The socket is there but this user may not open it.
    case noPermission(path: String)
    /// Any other connect error.
    case failed(path: String, reason: String)
}

/// Read-only checks for the first run: the session's socket and the `herdr` program. Sends nothing to herdr.
public enum ConnectionCheck {
    public static func diagnose(session: HerdrSession, environment: [String: String] = ProcessInfo.processInfo.environment,
                                home: String = NSHomeDirectory(), usual: [String]? = nil) -> ConnectionProblem? {
        let path = session.socketPath
        let e = connectError(path)
        switch e {
        case 0: return nil
        case ENOENT, ENOTDIR, ECONNREFUSED:
            guard findHerdr(environment: environment, home: home, usual: usual) != nil else { return .herdrMissing }
            return .notRunning(command: (["herdr"] + session.cliPrefix).joined(separator: " "))
        case EACCES, EPERM: return .noPermission(path: path)
        default: return .failed(path: path, reason: String(cString: strerror(e)))
        }
    }

    /// Connects to `path` once and closes again (no request). 0: a server listens; else the connect errno.
    static func connectError(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return ENAMETOOLONG }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return rc == 0 ? 0 : errno
    }

    /// The `herdr` program: `HERDR_BIN`, else on `PATH`, else in the usual install folders (a Finder launch has a short
    /// `PATH`). Nil: none. `usual`: those folders (nil: `usualFolders`).
    public static func findHerdr(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory(), usual: [String]? = nil) -> String? {
        let onPath = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/herdr" }
        let usual = (usual ?? usualFolders(home: home)).map { $0 + "/herdr" }
        return ([environment["HERDR_BIN"]].compactMap { $0 } + onPath + usual).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Where herdr is installed when it is not on `PATH`: its installer's folder first, then Homebrew, then cargo.
    public static func usualFolders(home: String) -> [String] { [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", home + "/.cargo/bin"] }

    /// Why a terminal cannot start when `findHerdr` finds nothing.
    public static let notFound = "herdr not found on PATH or in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, ~/.cargo/bin."

    /// Connected but no `herdr` program where the app looks: the agents show, but terminals cannot start. Nil: found.
    public static func programWarning(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory(), usual: [String]? = nil) -> String? {
        findHerdr(environment: environment, home: home, usual: usual) == nil ? "herdr program not found: terminals can't start" : nil
    }
}

extension ConnectionProblem {
    public static let herdrSite = URL(string: "https://herdr.dev")!

    /// One line for the sidebar's connection footer.
    public var short: String {
        switch self {
        case .herdrMissing: "herdr is not installed"
        case .notRunning: "herdr is not running"
        case .noPermission: "No access to herdr's socket"
        case .failed: "Cannot connect to herdr"
        }
    }

    public var title: String {
        switch self {
        case .herdrMissing: "herdr Is Not Installed"
        case .notRunning: "herdr Is Not Running"
        case .noPermission: "Cannot Open herdr's Socket"
        case .failed: "Cannot Connect to herdr"
        }
    }

    /// What to do next, in full sentences.
    public var detail: String {
        switch self {
        case .herdrMissing:
            "Flockbook shows the agents that run in herdr. Install herdr, start it in a terminal, then come back. Flockbook connects by itself."
        case .notRunning:
            "Start herdr in a terminal with this command. Flockbook connects by itself when herdr starts."
        case .noPermission(let path):
            "macOS does not let Flockbook open \((path as NSString).abbreviatingWithTildeInPath). Quit herdr, start it again as your own user, then try again."
        case .failed(let path, let reason):
            "Connecting to \((path as NSString).abbreviatingWithTildeInPath) failed: \(reason). Quit herdr, start it again, then try again."
        }
    }

    /// The command to copy into a terminal, if the next step is one.
    public var command: String? {
        if case .notRunning(let c) = self { return c }
        return nil
    }

    /// A page to open, if the next step is one.
    public var link: URL? { self == .herdrMissing ? Self.herdrSite : nil }
}
