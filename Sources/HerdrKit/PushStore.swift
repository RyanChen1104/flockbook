import CryptoKit
import Foundation

/// Phones' push subscriptions, one per paired device. In memory for checks; `FilePushStore` keeps them on disk.
@MainActor public class MemoryPushStore {
    public private(set) var all: [PushSubscription] = []
    public init() {}
    /// The last save that failed (nil: saved). Shown in Settings.
    public internal(set) var saveError: String?
    /// Replaces the device's subscription. False: not valid, or not saved; nothing kept.
    @discardableResult public func add(_ s: PushSubscription) -> Bool {
        guard s.isValid else { return false }
        let before = all
        all.removeAll { $0.device == s.device || $0.endpoint == s.endpoint }
        all.append(s)
        let pending = pendingRemoval
        pendingRemoval.remove(s.endpoint)
        guard changed() else { all = before; pendingRemoval = pending; return false }
        pendingRemoval = []   // the file now matches memory
        return true
    }
    /// Gone from memory at once (nothing more is sent to it). False: the file still holds it (`saveError`); it stays in
    /// `pendingRemoval` and every later save tries again (`retrySave`). Removing it again saves again.
    @discardableResult public func remove(device: String, endpoint: String? = nil) -> Bool {
        remove { $0.device == device && (endpoint == nil || $0.endpoint == endpoint) }
    }
    /// After a 404 / 410 from the push service.
    @discardableResult public func remove(endpoint: String) -> Bool {
        remove { $0.endpoint == endpoint }
    }
    private func remove(where gone: (PushSubscription) -> Bool) -> Bool {
        let removed = all.filter(gone)
        all.removeAll(where: gone)
        pendingRemoval.formUnion(removed.map(\.endpoint))
        return retrySave()
    }
    /// Endpoints removed here but still in the file (its save failed). Never sent to. Lost if the app quits before a
    /// save works: the file brings them back on the next start.
    public private(set) var pendingRemoval: Set<String> = []
    /// Saves again when a removal is pending or the last save failed. True: the file matches. While a removal is
    /// pending, the store's own timer calls it every `retryEvery` (with or without the hub running).
    @discardableResult public func retrySave() -> Bool {
        guard !pendingRemoval.isEmpty || saveError != nil else { return true }
        guard changed() else { scheduleRetry(); return false }
        pendingRemoval = []
        retryTask?.cancel(); retryTask = nil
        return true
    }
    /// The retry timer is on (a removal is pending).
    public var retrying: Bool { retryTask != nil }
    /// After each timer retry (the app refreshes Settings).
    public var onRetry: (@MainActor () -> Void)?
    var retryEvery: Duration = .seconds(2)
    private var retryTask: Task<Void, Never>?
    private func scheduleRetry() {
        guard retryTask == nil, !pendingRemoval.isEmpty else { return }
        let every = retryEvery
        retryTask = Task { @MainActor [weak self] in
            while (try? await Task.sleep(for: every)) != nil {
                guard let self else { return }
                let saved = self.retrySave()
                self.onRetry?()
                if saved { return }
            }
        }
    }
    func load(_ subs: [PushSubscription]) { all = subs }
    /// Saves; false when that failed.
    func changed() -> Bool { true }
}

/// Subscriptions in a JSON file, mode 600 (an endpoint is a capability to push to the phone).
@MainActor public final class FilePushStore: MemoryPushStore {
    public let url: URL
    public init(url: URL, retryEvery: Duration = .seconds(2)) {
        self.url = url
        super.init()
        self.retryEvery = retryEvery
        if let data = try? Data(contentsOf: url) {
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            load((try? d.decode([PushSubscription].self, from: data)) ?? [])
        }
    }
    override func changed() -> Bool {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try PrivateFile.write(try e.encode(all), to: url); saveError = nil; return true }
        catch { saveError = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"; return false }
    }
}

/// The hub's VAPID key pair: a P-256 signing key in a file, mode 600, next to the hub's TLS key. Made on first use.
/// Not the Keychain: an ad-hoc signed app would ask the owner again after every rebuild (see `FileDeviceStore`).
public enum VAPIDKeyFile {
    /// The key in `url`, or a new one written there. Throws when the file exists but does not hold a key (a new key
    /// would silently break every phone's subscription) or cannot be written.
    public static func loadOrCreate(at url: URL) throws -> P256.Signing.PrivateKey {
        if let data = try? Data(contentsOf: url) {
            guard let raw = Base64URL.decode(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                  let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) else { throw WebPushError.badKey }
            return key
        }
        let key = P256.Signing.PrivateKey()
        try PrivateFile.write(Data(Base64URL.encode(key.rawRepresentation).utf8), to: url)
        return key
    }
}

/// A file only its owner can read: written to a temp file made with mode 600, then renamed over the target, so no
/// reader ever sees it with another mode or half written. The folder is made 700.
public enum PrivateFile {
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appending(path: ".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let ok = data.withUnsafeBytes { p in Darwin.write(fd, p.baseAddress, p.count) == p.count }
        close(fd)
        guard ok, rename(tmp.path, url.path) == 0 else { unlink(tmp.path); throw CocoaError(.fileWriteUnknown) }
    }
}
