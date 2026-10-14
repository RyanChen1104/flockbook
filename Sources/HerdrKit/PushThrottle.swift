import Foundation

/// How often the Mac pushes to phones. One kind per agent at most once in `perAgent` (2 min); all kinds together at
/// most `perMinute` (6) in any 60 s. Over that, messages are held and counted; `flush` later sends one "N more" message.
public struct PushThrottle: Sendable {
    public enum Kind: String, Sendable, Hashable, Codable { case needsYou, done, message }
    public enum Decision: Sendable, Hashable {
        /// Send it. `more`: held messages to mention with it ("+N more"), now counted as told.
        case send(more: Int)
        /// The same agent and kind was pushed within `perAgent`: drop it.
        case repeated
        /// Over `perMinute`: held; `flush` reports it.
        case held
    }

    public var perAgent: TimeInterval = 120
    public var perMinute = 6
    private var lastByKey: [String: Date] = [:]
    private var sent: [Date] = []
    private var held = 0

    public init() {}

    public mutating func decide(agent: String, kind: Kind, now: Date) -> Decision {
        let key = kind.rawValue + "\u{0}" + agent
        if let last = lastByKey[key], now.timeIntervalSince(last) < perAgent { return .repeated }
        guard hasRoom(now) else { held += 1; return .held }
        lastByKey[key] = now
        sent.append(now)
        defer { held = 0 }
        return .send(more: held)
    }

    /// Held messages to report once the minute has room again: one push "N more". 0: nothing to send.
    public mutating func flush(now: Date) -> Int {
        guard held > 0, hasRoom(now) else { return 0 }
        sent.append(now)
        defer { held = 0 }
        return held
    }

    /// Fewer than `perMinute` pushes in the 60 s before `now`. Drops older times.
    private mutating func hasRoom(_ now: Date) -> Bool {
        sent.removeAll { now.timeIntervalSince($0) >= 60 }
        return sent.count < perMinute
    }
}
