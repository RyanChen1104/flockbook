import Foundation

public struct HerdrSession: Sendable, Hashable {
    /// herdr's session name (on the host when `remote` is set); nil: herdr's default session.
    public let name: String?
    /// The API socket the app talks to. For a remote host it is the local relay socket (`RemoteBridge`).
    public let socketPath: String
    /// nil: herdr on this Mac.
    public let remote: RemoteHost?

    public init(name: String?, socketPath: String, remote: RemoteHost? = nil) {
        self.name = name; self.socketPath = socketPath; self.remote = remote
    }

    private static var configDir: String { NSHomeDirectory() + "/.config/herdr" }

    public static func `default`() -> HerdrSession {
        HerdrSession(name: nil, socketPath: configDir + "/herdr.sock")
    }

    public static func named(_ name: String) -> HerdrSession {
        HerdrSession(name: name, socketPath: configDir + "/sessions/\(name)/herdr.sock")
    }

    /// herdr session `name` (nil: default) on `host`, through a relay socket in `RemoteHost.runtimeDir`. The socket name
    /// is a hash of the host and session, so two windows on the same pair share nothing but the name.
    public static func remote(_ host: RemoteHost, name: String?) -> HerdrSession {
        HerdrSession(name: name, socketPath: RemoteHost.runtimeDir + "/api-\(relayKey(host, name)).sock", remote: host)
    }

    /// FNV-1a of the host and session, 16 hex digits.
    static func relayKey(_ host: RemoteHost, _ name: String?) -> String {
        let key: String
        switch host.via {
        case .ssh(let d): key = "ssh\u{0}" + d + "\u{0}" + (name ?? "")
        case .local: key = "local\u{0}" + (name ?? "")
        }
        var h: UInt64 = 0xcbf29ce484222325
        for b in key.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }

    /// `--session <name>` wins, then env `HERDR_DESK_SESSION`, otherwise the default session. `--remote <destination>`
    /// (or env `HERDR_DESK_REMOTE`) puts that session on an SSH host; `--remote-local` runs the host side on this Mac
    /// (checks). A destination `RemoteHost.destinationProblem` refuses is ignored with a line on stderr.
    public static func fromLaunch(arguments: [String], environment: [String: String]) -> HerdrSession {
        var name: String?
        if let i = arguments.firstIndex(of: "--session"), arguments.indices.contains(i + 1) {
            name = arguments[i + 1]
        } else if let n = environment["HERDR_DESK_SESSION"], !n.isEmpty { name = n }
        var host: RemoteHost?
        if arguments.contains("--remote-local") {
            host = RemoteHost(via: .local)
        } else if let d = arguments.firstIndex(of: "--remote").flatMap({ arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil })
                    ?? environment["HERDR_DESK_REMOTE"].flatMap({ $0.isEmpty ? nil : $0 }) {
            do { host = try RemoteHost.ssh(d) } catch { FileHandle.standardError.write(Data("flockbook: --remote ignored: \(error)\n".utf8)) }
        }
        if let host { return remote(host, name: name) }
        return name.map(named) ?? .default()
    }

    /// Args for the `herdr` CLI so subprocesses hit this session, never one inherited from env.
    var cliPrefix: [String] { name.map { ["--session", $0] } ?? [] }
}
