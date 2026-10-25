import HerdrKit
import SwiftUI

extension ContentTests {
    /// Synthetic range failures: the visible tail stays readable, loading ends, and a manual retry can reach the start.
    static func earlierFailure() async {
        var failures = 0
        func step(_ name: String, _ ok: Bool) {
            if !ok { failures += 1 }
            print("earlier-failure: \(name) \(ok ? "ok" : "FAIL")")
        }
        ConversationProbe.enabled = true
        let state = EarlierFailureState()
        let (win, _) = offscreen(EarlierFailureView(state: state), NSSize(width: 800, height: 500))
        try? await Task.sleep(for: .milliseconds(600))
        step("the retry action is present", ConversationProbe.pressEarlier != nil)
        ConversationProbe.pressEarlier?()
        try? await Task.sleep(for: .seconds(1))
        step("failure ends loading and shows an explanation", ConversationProbe.earlierFailed && ConversationProbe.loading == .zero)
        step("the tail remains and retry stays available", state.items.count == 3 && ConversationProbe.pressEarlier != nil)
        // Give automatic scroll/layout reactions time to run: a failure cannot keep asking the host.
        try? await Task.sleep(for: .seconds(1))
        step("no automatic retries after failure", state.reads == 1)
        ConversationProbe.pressEarlier?()
        try? await Task.sleep(for: .seconds(1))
        step("manual retry clears the error and reaches the start", state.reads == 2 && !ConversationProbe.earlierFailed && ConversationProbe.pressEarlier == nil && ConversationProbe.loading == .zero)
        win.orderOut(nil)
        print("earlier-failure: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        NSApp.terminate(nil)
    }
}

@MainActor @Observable private final class EarlierFailureState {
    var reads = 0
    let items = (0..<3).map { ConversationItem(id: "earlier-\($0)", kind: .userText("Synthetic message \($0)")) }
}

private struct EarlierFailureView: View {
    let state: EarlierFailureState
    var body: some View {
        ConversationView(items: state.items, agentName: "test", loadState: .ready, onLoadEarlier: {
            state.reads += 1
            return state.reads == 1 ? .failed : .end
        })
    }
}
