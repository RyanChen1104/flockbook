import Foundation

/// Asked right before every key of an input that a remote device started: the pane must still show the agent the
/// checks saw, and `allowed` (the device's level and Allow input now) must still say yes. A refusal stops the
/// input there; nothing more is sent. herdr has no compare-and-send, so the moment between the last read and the
/// key stays; `HerdrClient.passes` keeps it to one screen read and a main-actor hop.
public struct KeyGate: Sendable {
    public var agent: Agent?
    public var allowed: (@MainActor @Sendable () -> Bool)?
    public init(agent: Agent?, allowed: (@MainActor @Sendable () -> Bool)?) { self.agent = agent; self.allowed = allowed }
}

/// A `KeyGate` said no: the input stopped, the keys after it were not sent.
public struct KeyGateStop: Error, Sendable, Hashable, CustomStringConvertible {
    public init() {}
    public var description: String { "stopped: the pane, its agent or this device's input level changed" }
}

extension HerdrClient {
    /// True when the next key may go: the pane still shows the gate's agent (same kind and session; fresh snapshot),
    /// then `ok` holds on a fresh screen read, then `allowed()`. The screen is read last, right before the answer.
    /// No gate: true, nothing read.
    public func passes(_ gate: KeyGate?, paneId: String, screen ok: (@Sendable (String) -> Bool)? = nil) async -> Bool {
        guard let gate else { return true }
        if let seen = gate.agent { guard await showsAgent(seen, paneId: paneId) else { return false } }
        if let ok { guard let s = try? await visibleText(paneId: paneId), ok(s) else { return false } }
        if let allowed = gate.allowed { guard await allowed() else { return false } }
        return true
    }

    /// Throws `KeyGateStop` when `passes` says no.
    func gated(_ gate: KeyGate?, paneId: String, screen ok: (@Sendable (String) -> Bool)? = nil) async throws {
        guard await passes(gate, paneId: paneId, screen: ok) else { throw KeyGateStop() }
    }

    /// The pane shows `seen` now: same agent kind and session (fresh snapshot).
    func showsAgent(_ seen: Agent, paneId: String) async -> Bool {
        guard let ws = try? await snapshot(), let a = ws.flatMap(\.tabs).flatMap(\.panes).first(where: { $0.id == paneId })?.agent else { return false }
        return a.kind == seen.kind && a.sessionId == seen.sessionId
    }
}
