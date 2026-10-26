import Foundation

/// Check readiness, not a guessed delay. A missing condition still fails at the deadline.
@MainActor enum CheckWait {
    static func until(_ timeout: Duration = .seconds(5), _ ready: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if ready() { return true }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        return ready()
    }
}
