import CryptoKit
import Foundation
@testable import HerdrKit

/// What the Mac pushes and when: the notice text, the status changes that trigger one, "Mac in use", the throttle,
/// and a gone subscription. A recording sender; nothing leaves the process.
@MainActor func checksPushCenter() async {
    // The notice: agent title, status, where; no conversation text; cut to size; small payload.
    func agent(_ status: AgentStatus, title: String = "Fix the build") -> Agent {
        Agent(name: "claude", kind: "claude", status: status, sessionId: nil, title: title)
    }
    func ws(_ status: AgentStatus, title: String = "Fix the build", pane: String = "w1:p1") -> [Workspace] {
        [Workspace(id: "w1", label: "site", tabs: [Tab(id: "t1", label: "build", number: 1,
                                                       panes: [Pane(id: pane, terminalId: "x", cwd: "/", agent: agent(status, title: title))], status: status)])]
    }
    let n = PushNotice.agent(.needsYou, workspace: "site", tab: "build", agent: agent(.blocked), pane: "w1:p1")
    check(n.title == "Needs you · Fix the build" && n.body == "claude · site · build" && n.pane == "w1:p1" && n.tag == "w1:p1",
          "push notice: needs you, the agent's title, where (\(n.title) / \(n.body))")
    let d = PushNotice.agent(.done, workspace: "site", tab: "build", agent: agent(.done, title: ""), pane: "w1:p1")
    check(d.title == "Done · build", "push notice: done; no agent title -> the tab (\(d.title))")
    let long = PushNotice(title: String(repeating: "t", count: 500), body: String(repeating: "\u{1F600}", count: 500), tag: "x", pane: "p")
    check(long.title.count == PushNotice.maxTitle && long.body.count == PushNotice.maxBody, "push notice: title and body cut")
    check(long.payload.count < WebPush.maxPlaintext, "push notice: payload fits one push (\(long.payload.count) bytes)")
    let back = try? JSONDecoder().decode([String: String].self, from: n.payload)
    check(back == ["title": n.title, "body": n.body, "tag": "w1:p1", "pane": "w1:p1"], "push notice: JSON for sw.js")

    // Triggers: a pane turning blocked or done; nothing on the first look, on a repeat, or for other changes.
    var t = PushTrigger()
    check(t.update(ws(.blocked)).isEmpty, "push trigger: the first snapshot only records")
    check(t.update(ws(.blocked)).isEmpty, "push trigger: still blocked -> nothing")
    check(t.update(ws(.working)).isEmpty, "push trigger: blocked -> working -> nothing")
    let done = t.update(ws(.done))
    check(done.map(\.kind) == [.done] && done.first?.notice.pane == "w1:p1", "push trigger: working -> done")
    check(t.update(ws(.idle)).isEmpty, "push trigger: done -> idle (seen) -> nothing")
    let blocked = t.update(ws(.blocked))
    check(blocked.map(\.kind) == [.needsYou] && blocked.first?.notice.title == "Needs you · Fix the build", "push trigger: idle -> blocked")
    check(t.update(ws(.blocked, pane: "w1:p9")).map(\.kind) == [.needsYou], "push trigger: a new pane that is blocked")
    check(t.update([]).isEmpty, "push trigger: panes gone -> nothing")

    // Mac in use: needs you and done wait for the owner to be away; the setting turns that off.
    let p = PushPolicy(doneEnabled: true, onlyWhenAway: true)
    check(!p.allows(.needsYou, idle: 30, locked: false), "push policy: Mac in use -> no push")
    check(p.allows(.needsYou, idle: PushPolicy.away, locked: false) && p.allows(.done, idle: 0, locked: true), "push policy: idle or locked -> push")
    check(PushPolicy(doneEnabled: true, onlyWhenAway: false).allows(.needsYou, idle: 0, locked: false), "push policy: always, when set")
    check(!PushPolicy(doneEnabled: false, onlyWhenAway: false).allows(.done, idle: 999, locked: true)
          && PushPolicy(doneEnabled: false, onlyWhenAway: false).allows(.needsYou, idle: 0, locked: false), "push policy: done can be turned off")
    check(PushPolicy(doneEnabled: true, onlyWhenAway: true).allows(.message, idle: 0, locked: false), "push policy: an agent's own message always goes")

    // The center: to every subscription, high urgency for needs you, throttled, a gone endpoint removed.
    let store = MemoryPushStore()
    let p256 = "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4", auth = "AAECAwQFBgcICQoLDA0ODw"
    store.add(PushSubscription(device: "d1", endpoint: "https://fcm.googleapis.com/fcm/send/a", p256dh: p256, auth: auth))
    store.add(PushSubscription(device: "d2", endpoint: "https://web.push.apple.com/b", p256dh: p256, auth: auth))
    final class Log: @unchecked Sendable { var sent: [(String, String, WebPushSender.Urgency)] = []; var gone: Set<String> = [] }
    let log = Log()
    let c = PushCenter(store: store) { payload, s, u in
        let body = (try? JSONDecoder().decode([String: String].self, from: payload))?["body"] ?? "?"
        await MainActor.run { log.sent.append((s.device, body, u)) }
        return log.gone.contains(s.device) ? .gone : .sent
    }
    let now = Date()
    check(await c.notify(n, kind: .needsYou, now: now) == 2 && log.sent.allSatisfy { $0.2 == .high }, "push center: needs you -> every device, urgency high")
    check(await c.notify(n, kind: .needsYou, now: now.addingTimeInterval(10)) == 0, "push center: the same agent again soon -> dropped")
    log.sent = []
    _ = await c.notify(d, kind: .done, now: now.addingTimeInterval(11))
    check(log.sent.count == 2 && log.sent.allSatisfy { $0.2 == .normal }, "push center: done -> urgency normal")
    log.gone = ["d2"]
    let r = await c.test(device: "d2")
    check(r == .gone && store.all.map(\.device) == ["d1"], "push center: a test to a gone subscription removes it")
    log.sent = []
    check(await c.test(device: "d1") == .sent && log.sent.first?.1.isEmpty == false, "push center: a test notification, not throttled")
    check(await c.test(device: "none") == nil, "push center: test to a device without a subscription -> nil")
    // Over the minute: held, then one "more" push.
    for i in 0..<10 { _ = await c.notify(PushNotice(title: "m\(i)", body: "", tag: "m\(i)", pane: nil), kind: .message, now: now.addingTimeInterval(20)) }
    log.sent = []
    check(await c.flush(now: now.addingTimeInterval(200)) == 1 && log.sent.first?.1.contains("more") == true, "push center: held pushes -> one 'more' push later")
}
