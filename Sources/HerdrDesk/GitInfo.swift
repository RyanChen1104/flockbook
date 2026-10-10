import Foundation

enum GitInfo {
    private static let cache = Cache()

    /// Current branch of the repo containing `cwd`, or nil if unreadable. Read-only `git` call, 2 s timeout,
    /// cached per cwd for 10 s.
    static func branch(cwd: String) async -> String? {
        let path = (cwd as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if let hit = cache.get(path) { return hit }
        let result = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async { c.resume(returning: run(path)) }
        }
        cache.set(path, result)
        return result
    }

    private static func run(_ path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = Pipe()
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + 2) == .timedOut { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: (at: Date, value: String?)] = [:]
        /// Outer optional = cache miss.
        func get(_ k: String) -> String?? {
            lock.lock(); defer { lock.unlock() }
            guard let e = map[k], Date().timeIntervalSince(e.at) < 10 else { return nil }
            return .some(e.value)
        }
        func set(_ k: String, _ v: String?) { lock.lock(); map[k] = (Date(), v); lock.unlock() }
    }
}
