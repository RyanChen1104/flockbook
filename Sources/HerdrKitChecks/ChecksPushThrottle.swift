import Foundation
@testable import HerdrKit

func checksPushThrottle() async throws {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var t = PushThrottle()
    check(t.decide(agent: "a", kind: .needsYou, now: t0) == .send(more: 0), "throttle: first push goes")
    check(t.decide(agent: "a", kind: .needsYou, now: t0 + 60) == .repeated, "throttle: same agent and kind within 2 min -> dropped")
    check(t.decide(agent: "a", kind: .done, now: t0 + 61) == .send(more: 0), "throttle: another kind of the same agent goes")
    check(t.decide(agent: "a", kind: .needsYou, now: t0 + 121) == .send(more: 0), "throttle: same agent and kind after 2 min goes")

    var m = PushThrottle()
    for i in 0..<6 { _ = m.decide(agent: "agent\(i)", kind: .done, now: t0 + Double(i)) }
    check(m.decide(agent: "x", kind: .done, now: t0 + 10) == .held, "throttle: 7th push within a minute is held")
    check(m.decide(agent: "y", kind: .message, now: t0 + 20) == .held, "throttle: 8th held too")
    // An agent waiting for approval is never folded into "+N more": its name must reach the phone.
    check(m.decide(agent: "w", kind: .needsYou, now: t0 + 25) == .send(more: 0), "throttle: needs-you goes even when the minute is full")
    check(m.decide(agent: "w", kind: .needsYou, now: t0 + 26) == .repeated, "throttle: needs-you still once per agent in 2 min")
    check(m.flush(now: t0 + 30) == 0, "throttle: no flush while the minute is still full")
    check(m.decide(agent: "z", kind: .done, now: t0 + 61) == .send(more: 2), "throttle: next push after room frees carries +2 more")
    check(m.flush(now: t0 + 62) == 0, "throttle: held ones told once")

    var f = PushThrottle()
    for i in 0..<6 { _ = f.decide(agent: "agent\(i)", kind: .done, now: t0) }
    _ = f.decide(agent: "late", kind: .done, now: t0 + 5)
    check(f.flush(now: t0 + 61) == 1, "throttle: flush reports held pushes once the minute has room")
    check(f.flush(now: t0 + 62) == 0, "throttle: flush only once")
    check(f.decide(agent: "late", kind: .done, now: t0 + 63) == .send(more: 0), "throttle: a held push did not count as sent for its agent")
}
