import Foundation

/// A herdr machine the owner saved in Settings: an SSH destination, the herdr session on it (nil: its default session)
/// and a name for the window. Nothing else: keys, passwords and host keys stay with OpenSSH.
public struct RemoteMachine: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var label: String?
    public var destination: String
    public var session: String?

    /// The name lists and the window show: the label, else the destination.
    public var title: String { label ?? destination }
    /// The destination and the session, for the line under the title.
    public var detail: String { destination + (session.map { " · \($0)" } ?? "") }

    public var host: RemoteHost { RemoteHost(via: .ssh(destination: destination)) }
    /// The session the app shows for this machine.
    public var herdrSession: HerdrSession { .remote(host, name: session) }
}

/// The saved machines and the one the app shows (`selected` nil: herdr on this Mac), in one defaults key as JSON. The
/// store is passed in, so checks use their own. Entries a hand edit made invalid are dropped when read, never passed to ssh.
public struct RemoteMachines {
    /// The defaults key: `{"machines": [{id, label?, destination, session?}], "selected": id?}`.
    public static let key = "remoteMachines"
    /// Longest label kept, in characters.
    public static let labelLimit = 40

    public private(set) var machines: [RemoteMachine] = []
    public private(set) var selected: String?
    private let defaults: UserDefaults

    /// Why a change was refused, in words for the Settings row.
    public struct Refusal: Error, CustomStringConvertible, LocalizedError {
        public let description: String
        init(_ s: String) { description = s }
        public var errorDescription: String? { description }
    }

    private struct Stored: Codable {
        var machines: [RemoteMachine]
        var selected: String?
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        var seen = Set<String>()
        machines = s.machines.filter { m in
            Self.problem(destination: m.destination, session: m.session) == nil && seen.insert(m.id).inserted
        }.map { var m = $0; m.label = Self.cleanLabel(m.label); return m }
        selected = s.selected.flatMap { id in machines.contains { $0.id == id } ? id : nil }
    }

    public var selectedMachine: RemoteMachine? { selected.flatMap { id in machines.first { $0.id == id } } }

    // MARK: - Changes (each one saved at once)

    @discardableResult
    public mutating func add(destination: String, session: String?, label: String?) throws -> RemoteMachine {
        let m = RemoteMachine(id: UUID().uuidString, label: Self.cleanLabel(label), destination: destination, session: Self.cleanSession(session))
        try validate(m)
        machines.append(m)
        save()
        return m
    }

    public mutating func update(_ id: String, destination: String, session: String?, label: String?) throws {
        guard let i = machines.firstIndex(where: { $0.id == id }) else { throw Refusal("That machine is no longer in the list.") }
        let m = RemoteMachine(id: id, label: Self.cleanLabel(label), destination: destination, session: Self.cleanSession(session))
        try validate(m)
        machines[i] = m
        save()
    }

    /// Removing the selected machine selects this Mac.
    public mutating func remove(_ id: String) {
        machines.removeAll { $0.id == id }
        if selected == id { selected = nil }
        save()
    }

    /// nil: this Mac. An id that is not in the list is refused.
    public mutating func select(_ id: String?) throws {
        if let id, !machines.contains(where: { $0.id == id }) { throw Refusal("That machine is no longer in the list.") }
        selected = id
        save()
    }

    private func validate(_ m: RemoteMachine) throws {
        if let why = Self.problem(destination: m.destination, session: m.session) { throw Refusal(why) }
        if machines.contains(where: { $0.id != m.id && $0.destination == m.destination && $0.session == m.session }) {
            throw Refusal("This destination and session are already in the list.")
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Stored(machines: machines, selected: selected)) else { return }
        defaults.set(data, forKey: Self.key)
    }

    // MARK: - Validation

    /// Why `destination` or `session` cannot be saved; nil: fine. A ":" in the user part (`user:secret@host`) is refused:
    /// it would put a password in the settings store, and ssh logs in with keys only (BatchMode).
    public static func problem(destination: String, session: String?) -> String? {
        if let at = destination.lastIndex(of: "@"), destination[..<at].contains(":") {
            return "Do not put a password in the SSH destination: Flockbook logs in with your SSH keys."
        }
        return RemoteHost.destinationProblem(destination) ?? session.flatMap(sessionNameProblem)
    }

    /// Why `s` is not a herdr session name; nil: fine. Letters, digits, - _ . only, at most 64, not starting with "-" or
    /// ".": the name becomes a folder name on the host (no "/", no "." or "..") and a word after `--session`.
    public static func sessionNameProblem(_ s: String) -> String? {
        if s.isEmpty { return "Enter a session name, or leave it empty for herdr's default session." }
        if s.utf8.count > 64 { return "The session name is too long (64 characters at most)." }
        if s.hasPrefix("-") || s.hasPrefix(".") { return "A session name cannot start with “-” or “.”." }
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        if !s.unicodeScalars.allSatisfy(ok.contains) { return "Use only letters, digits and - _ . in the session name." }
        return nil
    }

    /// A label is one short line; blank is no label.
    static func cleanLabel(_ s: String?) -> String? {
        guard let s else { return nil }
        let line = String(String.UnicodeScalarView(s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
            .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : String(line.prefix(labelLimit))
    }

    /// Blank is herdr's default session.
    static func cleanSession(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }

    // MARK: - Launch

    /// The session the app shows. Launch flags win (`--session`, `--remote`, `--remote-local`, env `HERDR_DESK_SESSION`,
    /// `HERDR_DESK_REMOTE`): `HerdrSession.fromLaunch`. Otherwise the selected saved machine; none: herdr on this Mac.
    public static func launchSession(arguments: [String], environment: [String: String], defaults: UserDefaults) -> HerdrSession {
        if !launchFlags(arguments: arguments, environment: environment), let m = RemoteMachines(defaults: defaults).selectedMachine { return m.herdrSession }
        return HerdrSession.fromLaunch(arguments: arguments, environment: environment)
    }

    /// The launch names a session or a host itself, so the saved choice does not apply.
    public static func launchFlags(arguments: [String], environment: [String: String]) -> Bool {
        ["--session", "--remote", "--remote-local"].contains { arguments.contains($0) }
            || ["HERDR_DESK_SESSION", "HERDR_DESK_REMOTE"].contains { !(environment[$0] ?? "").isEmpty }
    }

    /// The machine's name for the window; nil for herdr on this Mac. A saved machine by its title, otherwise the
    /// destination (and session).
    public static func title(for session: HerdrSession, defaults: UserDefaults) -> String? {
        guard let host = session.remote else { return nil }
        guard case .ssh(let d) = host.via else { return host.label }
        if let m = RemoteMachines(defaults: defaults).machines.first(where: { $0.destination == d && $0.session == session.name }) { return m.title }
        return d + (session.name.map { " · \($0)" } ?? "")
    }

    // MARK: - Test

    /// The Test button's command line: herdr's API bridge answers `--check` with its banner. It needs ssh and herdr on the
    /// host, not a running server.
    public static func testCommand(session: String?) -> String {
        RemoteHost.herdrCommand(session: session, ["remote-api-bridge", "--check"])
    }

    /// Runs the test for `machine` (20 s at most) and reads the answer into one line.
    public static func test(_ machine: RemoteMachine) async -> (ok: Bool, text: String) {
        do {
            let r = try await machine.host.run(testCommand(session: machine.session), timeout: .seconds(20))
            return testOutcome(r, destination: machine.destination)
        } catch {
            return (false, "Could not start ssh: \(error)")
        }
    }

    /// What a test run says, in one line: ok, or the problem and what to do.
    public static func testOutcome(_ r: RemoteHost.Result, destination: String) -> (ok: Bool, text: String) {
        let out = String(decoding: r.stdout, as: UTF8.self), err = r.stderr
        if r.ok, out.contains("herdr-api-bridge") { return (true, "Connected: herdr answers on the host.") }
        if r.ok { return (false, "The host answered, but not as herdr's API bridge. Update herdr on the host.") }
        if r.status == -1 { return (false, "No answer in 20 seconds. Check the destination and your network.") }
        if r.status == 127 || err.contains(RemoteHost.herdrMissingMarker) {
            return (false, "herdr is not installed on the host, or not on its PATH, ~/.local/bin, Homebrew, ~/.cargo/bin, Nix or mise.")
        }
        if err.contains("Host key verification failed") || err.contains("HOST IDENTIFICATION HAS CHANGED") || err.contains("host key is known") {
            return (false, "The host key is unknown or changed. Run ssh \(destination) once in Terminal and check the key.")
        }
        if err.contains("Permission denied") || err.contains("Too many authentication failures") {
            return (false, "The host refused the login. Load your key with ssh-add, or name it in ~/.ssh/config.")
        }
        if err.contains("Could not resolve hostname") { return (false, "Host not found. Check the destination or your ~/.ssh/config.") }
        if err.contains("Connection refused") || err.contains("timed out") || err.contains("No route to host") {
            return (false, "No SSH server answers at that destination.")
        }
        let line = err.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return (false, line.isEmpty ? "Failed (exit \(r.status))." : "Failed: " + String(line.prefix(200)))
    }
}
