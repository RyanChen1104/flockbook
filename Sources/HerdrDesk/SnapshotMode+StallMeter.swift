import Foundation

extension ContentTests {
    /// Capture APIs may run nested event loops: their timer callbacks must remain excluded while the meter is paused.
    static func stallMeterCheck() async -> Bool {
        let meter = StallMeter()
        meter.start()
        defer { meter.stop() }
        try? await Task.sleep(for: .milliseconds(40))
        _ = meter.take()
        pausedWork(meter)
        let excluded = meter.take()
        blockingWork()
        let counted = meter.take()
        let ok = excluded < 0.05 && counted >= 0.29
        print("churn-test: paused nested-loop work excluded (\(Int(excluded * 1000)) ms), unpaused work counted (\(Int(counted * 1000)) ms) \(ok ? "ok" : "FAIL")")
        return ok
    }
    private static func pausedWork(_ meter: StallMeter) {
        meter.pause()
        _ = meter.take()   // isolate paused work from any scheduler delay that occurred before pause
        blockingWork()
        meter.resume()
    }
    private static func blockingWork() {
        Thread.sleep(forTimeInterval: 0.3)
        // Pump one overdue timer while still inside the caller's synchronous work, as a nested AppKit loop can do.
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}
