import Foundation

public struct HerdrSession: Sendable, Hashable {
    public let name: String?
    public let socketPath: String

    public init(name: String?, socketPath: String) { self.name = name; self.socketPath = socketPath }

    private static var configDir: String { NSHomeDirectory() + "/.config/herdr" }

    public static func `default`() -> HerdrSession {
        HerdrSession(name: nil, socketPath: configDir + "/herdr.sock")
    }

    public static func named(_ name: String) -> HerdrSession {
        HerdrSession(name: name, socketPath: configDir + "/sessions/\(name)/herdr.sock")
    }

    /// `--session <name>` wins, then env `HERDR_DESK_SESSION`, otherwise the default session.
    public static func fromLaunch(arguments: [String], environment: [String: String]) -> HerdrSession {
        if let i = arguments.firstIndex(of: "--session"), arguments.indices.contains(i + 1) {
            return named(arguments[i + 1])
        }
        if let n = environment["HERDR_DESK_SESSION"], !n.isEmpty { return named(n) }
        return .default()
    }

    /// Args for the `herdr` CLI so subprocesses hit this session, never one inherited from env.
    var cliPrefix: [String] { name.map { ["--session", $0] } ?? [] }
}
