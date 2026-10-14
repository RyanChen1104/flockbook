import CryptoKit
import Foundation

/// One push message for the PWA's service worker (`web/src/sw.ts`): JSON {title, body, tag, pane}. Agent notices carry
/// the agent's title, its status and where it runs: no conversation text.
public struct PushNotice: Codable, Hashable, Sendable {
    public static let maxTitle = 120, maxBody = 200
    /// UTF-8 bytes per field. JSON escaping at most doubles them (control characters are dropped), so a notice stays
    /// under 2.7 KB, below one push (`WebPush.maxPlaintext`, 3993).
    static let titleBytes = 300, bodyBytes = 600, idBytes = 200
    public var title: String
    public var body: String
    /// A newer notice with the same tag replaces the old one on the phone.
    public var tag: String?
    /// The pane the tap opens.
    public var pane: String?
    public init(title: String, body: String, tag: String?, pane: String?) {
        self.title = Self.clip(title, chars: Self.maxTitle, bytes: Self.titleBytes, newlines: false)
        self.body = Self.clip(body, chars: Self.maxBody, bytes: Self.bodyBytes, newlines: true)
        self.tag = tag.map { Self.clip($0, chars: Self.idBytes, bytes: Self.idBytes, newlines: false) }
        self.pane = pane.map { Self.clip($0, chars: Self.idBytes, bytes: Self.idBytes, newlines: false) }
    }

    /// At most `chars` characters and `bytes` UTF-8 bytes, cut between characters; control characters dropped (a
    /// newline kept when `newlines`).
    static func clip(_ s: String, chars: Int, bytes: Int, newlines: Bool) -> String {
        var out = "", used = 0, count = 0
        for c in s {
            if c.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) && !(newlines && c == "\n") { continue }
            let n = c.utf8.count
            guard count < chars, used + n <= bytes else { break }
            out.append(c); used += n; count += 1
        }
        return out
    }

    /// "Needs you · Fix the build", "claude · site · build" (as the PWA's list row).
    public static func agent(_ kind: PushThrottle.Kind, workspace: String, tab: String, agent: Agent, pane: String) -> PushNotice {
        let what = switch kind { case .needsYou: "Needs you"; case .done: "Done"; case .message: "Message" }
        let name = agent.title.isEmpty ? tab : agent.title
        let body = [agent.name, workspace, tab].filter { !$0.isEmpty }.joined(separator: " · ")
        return PushNotice(title: "\(what) · \(name)", body: body, tag: pane, pane: pane)
    }

    public var payload: Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)) ?? Data()
    }
}

/// Status changes worth a push: a pane turning blocked (needs you) or done. The first snapshot only records.
public struct PushTrigger: Sendable {
    public struct Event: Sendable { public var kind: PushThrottle.Kind; public var notice: PushNotice }
    private var last: [String: AgentStatus]?
    public init() {}

    public mutating func update(_ workspaces: [Workspace]) -> [Event] {
        var now: [String: AgentStatus] = [:]
        var out: [Event] = []
        for w in workspaces { for t in w.tabs { for p in t.panes {
            guard let a = p.agent else { continue }
            now[p.id] = a.status
            guard let last else { continue }
            let was = last[p.id]
            let kind: PushThrottle.Kind? = if a.status == .blocked, was != .blocked { .needsYou }
                else if a.status == .done, was == .working || was == .blocked { .done } else { nil }
            if let kind { out.append(Event(kind: kind, notice: .agent(kind, workspace: w.label, tab: t.label, agent: a, pane: p.id))) }
        } } }
        last = now
        return out
    }
}

/// When the Mac pushes. Needs you and done wait until the owner is away (idle for `away`, or the screen locked) unless
/// `onlyWhenAway` is off; done can be turned off. An agent's own message (`flockbook-notify`) always goes.
public struct PushPolicy: Sendable {
    public static let away: TimeInterval = 120
    public var doneEnabled: Bool
    public var onlyWhenAway: Bool
    public init(doneEnabled: Bool, onlyWhenAway: Bool) { self.doneEnabled = doneEnabled; self.onlyWhenAway = onlyWhenAway }
    public func allows(_ kind: PushThrottle.Kind, idle: TimeInterval, locked: Bool) -> Bool {
        if kind == .message { return true }
        if kind == .done, !doneEnabled { return false }
        return !onlyWhenAway || locked || idle >= Self.away
    }
}

/// Sends notices to every subscribed phone, throttled (`PushThrottle`); a subscription the push service calls gone
/// (404 / 410) is removed.
@MainActor public final class PushCenter {
    public typealias Deliver = @Sendable (Data, PushSubscription, WebPushSender.Urgency) async -> PushOutcome
    let store: MemoryPushStore
    private let deliver: Deliver
    private var throttle = PushThrottle()

    /// The app's center: real sends, only to push services on the allow list (`WebPushSender.send`).
    public convenience init(store: MemoryPushStore, key: P256.Signing.PrivateKey, subject: String = WebPushSender.subject,
                            known: @escaping @MainActor (String) -> Bool) {
        self.init(store: store, known: known) { await WebPushSender.send($0, to: $1, key: key, subject: subject, urgency: $2) }
    }
    /// Checks: a recording `deliver`.
    init(store: MemoryPushStore, known: @escaping @MainActor (String) -> Bool = { _ in true }, deliver: @escaping Deliver) {
        self.store = store; self.known = known; self.deliver = deliver
    }
    /// A device still paired. A subscription of any other device is dropped, never sent to (its removal may not have
    /// reached the file).
    private let known: @MainActor (String) -> Bool
    private var stopped = false
    /// Remote access off: nothing more is sent, also from a notify already waiting on the network.
    public func stop() { stopped = true }

    /// Throttled. Returns the number of phones it reached.
    @discardableResult public func notify(_ n: PushNotice, kind: PushThrottle.Kind, now: Date = Date()) async -> Int {
        guard !stopped, case .send(let more) = throttle.decide(agent: n.pane ?? n.tag ?? n.title, kind: kind, now: now) else { return 0 }
        var n = n
        if more > 0 { n = PushNotice(title: n.title, body: n.body.isEmpty ? "+\(more) more" : "\(n.body) · +\(more) more", tag: n.tag, pane: n.pane) }
        return await send(n, urgency: kind == .needsYou ? .high : .normal, to: store.all).filter { $0 == .sent }.count
    }

    /// Held pushes, once the minute has room: one "N more" push. Returns the phones reached.
    @discardableResult public func flush(now: Date = Date()) async -> Int {
        guard !stopped else { return 0 }
        let held = throttle.flush(now: now)
        guard held > 0 else { return 0 }
        let n = PushNotice(title: "Flockbook", body: "\(held) more agent updates. Open Flockbook to see them.", tag: "more", pane: nil)
        return await send(n, urgency: .normal, to: store.all).filter { $0 == .sent }.count
    }

    /// Settings > Send Test Notification: not throttled. Nil: the device has no subscription.
    public func test(device: String) async -> PushOutcome? {
        guard !stopped, let s = store.all.first(where: { $0.device == device }) else { return nil }
        let n = PushNotice(title: "Flockbook", body: "Test notification. Agents that need you will show up like this.", tag: "test", pane: nil)
        return await send(n, urgency: .normal, to: [s]).first
    }

    private func send(_ n: PushNotice, urgency: WebPushSender.Urgency, to subs: [PushSubscription]) async -> [PushOutcome] {
        let subs = subs.filter { s in
            if known(s.device) { return true }
            store.remove(device: s.device)
            return false
        }
        guard !stopped, !subs.isEmpty else { return [] }
        let payload = n.payload, deliver = deliver
        let results = await withTaskGroup(of: (String, PushOutcome).self) { g in
            for s in subs { g.addTask { (s.endpoint, await deliver(payload, s, urgency)) } }
            var out: [(String, PushOutcome)] = []
            for await r in g { out.append(r) }
            return out
        }
        for (endpoint, r) in results where r == .gone { store.remove(endpoint: endpoint) }
        return results.map(\.1)
    }
}
