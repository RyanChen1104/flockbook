import Foundation
import CryptoKit
import Security

// Paired devices and pairing (docs/design/remote-access.md, section 6). The hub keeps only a hash of each device
// token. Pairing: the hub shows a one-time offer (a secret in the QR code, 6 words to type), valid 5 minutes, single
// use; the client sends it in `pair` and gets a new device token.

/// Paired devices. Looked up on every message, so a revoke or a level change applies to open connections at once.
@MainActor public protocol HubDeviceStore: AnyObject {
    func device(token: String) -> HubDevice?
    func device(id: String) -> HubDevice?
    var all: [HubDeviceRecord] { get }
    func add(token: String, device: HubDevice, paired: Date)
    func setLevel(_ level: HubLevel, device id: String)
    func revoke(device id: String)
}

extension HubDeviceStore {
    public func add(token: String, device: HubDevice) { add(token: token, device: device, paired: Date()) }
}

/// A stored device: the token hash, never the token.
public struct HubDeviceRecord: Codable, Hashable, Sendable {
    public var device: HubDevice
    public var hash: String
    public var paired: Date
}

public enum HubToken {
    /// SHA-256 hex. Stores keep only this, never the token.
    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// `bytes` random bytes, base64url without padding (32 bytes = 43 characters).
    public static func random(bytes: Int = 32) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes, &b) == errSecSuccess, "no system randomness")
        return Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Devices in memory (tests). Subclasses persist on every change.
@MainActor public class MemoryDeviceStore: HubDeviceStore {
    fileprivate var records: [HubDeviceRecord] = []
    public init() {}
    public var all: [HubDeviceRecord] { records }
    public var hashes: [String] { records.map(\.hash) }
    public func add(token: String, device: HubDevice, paired: Date) {
        let h = HubToken.hash(token)
        records.removeAll { $0.hash == h || $0.device.id == device.id }
        records.append(HubDeviceRecord(device: device, hash: h, paired: paired))
    }
    public func setLevel(_ level: HubLevel, device id: String) {
        for i in records.indices where records[i].device.id == id { records[i].device.level = level }
    }
    public func revoke(device id: String) { records.removeAll { $0.device.id == id } }
    public func device(token: String) -> HubDevice? { let h = HubToken.hash(token); return records.first { $0.hash == h }?.device }
    public func device(id: String) -> HubDevice? { records.first { $0.device.id == id }?.device }
}

/// Devices in a JSON file, mode 600. Token hashes are not secrets (a 256-bit random token cannot be found from its
/// hash), so a file is enough; the Keychain would ask the owner again after every rebuild of an ad-hoc signed app.
@MainActor public final class FileDeviceStore: MemoryDeviceStore {
    public let url: URL
    public init(url: URL) {
        self.url = url
        super.init()
        if let data = try? Data(contentsOf: url) {
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            records = (try? d.decode([HubDeviceRecord].self, from: data)) ?? []
        }
    }
    public override func add(token: String, device: HubDevice, paired: Date) { super.add(token: token, device: device, paired: paired); save() }
    public override func setLevel(_ level: HubLevel, device id: String) { super.setLevel(level, device: id); save() }
    public override func revoke(device id: String) { super.revoke(device: id); save() }
    private func save() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(records) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Created 600 before the content goes in.
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// One pairing offer, shown on the hub.
public struct HubPairOffer: Hashable, Sendable {
    /// For the QR code: 256-bit, base64url.
    public let secret: String
    /// To type (a Mac has no camera step): 6 words of 8 bits.
    public let words: [String]
    public let expires: Date
    public var code: String { words.joined(separator: " ") }

    /// The QR code's link. Secret and certificate fingerprint go in the fragment, which a browser never sends.
    public func link(base: URL, fingerprint: String?) -> URL {
        var s = base.absoluteString
        if !s.hasSuffix("/") { s += "/" }
        s += "#pair=\(secret)"
        if let fingerprint { s += "&fp=\(fingerprint)" }
        return URL(string: s)!
    }
}

/// The hub's pairing state: at most one open offer.
@MainActor public final class HubPairing {
    public static let lifetime: TimeInterval = 300
    /// Wrong tries in all before the offer ends (6 words = 48 bits: a guess stays hopeless).
    public static let maxTries = 20
    /// Wrong tries from one address before that address is refused for this offer: one peer cannot end the
    /// owner's offer, and cannot keep guessing.
    public static let maxTriesPerSource = 3

    private let devices: HubDeviceStore
    private let now: () -> Date
    private var offerNow: HubPairOffer?
    private var tries = 0
    private var triesBySource: [String: Int] = [:]

    public init(devices: HubDeviceStore, now: @escaping () -> Date = Date.init) { self.devices = devices; self.now = now }

    /// The open offer; nil when none or expired.
    public var open: HubPairOffer? {
        guard let o = offerNow, now() < o.expires else { return nil }
        return o
    }

    /// A new offer. It replaces any open one.
    @discardableResult
    public func offer() -> HubPairOffer {
        var g = SystemRandomNumberGenerator()
        let o = HubPairOffer(secret: HubToken.random(), words: (0..<6).map { _ in Self.words[Int(g.next() % 256)] },
                             expires: now().addingTimeInterval(Self.lifetime))
        offerNow = o; tries = 0; triesBySource = [:]
        return o
    }

    public func cancel() { offerNow = nil; tries = 0; triesBySource = [:] }

    /// Pairs a device when `input` is the open offer's secret or its words (any case, any separators). The offer
    /// is then used up. New devices get level `read`; input is turned on per device on the hub.
    public func redeem(_ input: String, name: String, source: String = "") -> (token: String, device: HubDevice)? {
        guard let o = open else { offerNow = nil; return nil }
        guard triesBySource[source, default: 0] < Self.maxTriesPerSource else { return nil }
        let typed = Self.normalize(input)
        let hit = !input.isEmpty && (Self.same(input, o.secret) || (!typed.isEmpty && Self.same(typed, o.code)))
        guard hit else {
            tries += 1
            triesBySource[source, default: 0] += 1
            if tries >= Self.maxTries { cancel() }
            return nil
        }
        cancel()
        let token = HubToken.random()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = HubDevice(id: "d-" + HubToken.random(bytes: 6), name: trimmed.isEmpty ? "Device" : String(trimmed.prefix(60)), level: .read)
        devices.add(token: token, device: d, paired: now())
        return (token, d)
    }

    /// Words only, lowercased, one space apart.
    static func normalize(_ s: String) -> String {
        s.lowercased().split { !$0.isLetter }.joined(separator: " ")
    }
    /// Compares hashes, so the time taken says nothing about how much of the input matched.
    private static func same(_ a: String, _ b: String) -> Bool { HubToken.hash(a) == HubToken.hash(b) }

    public static let words: [String] = [
        "acorn", "actor", "adult", "agent", "album", "alarm", "alley", "amber", "angle", "ankle", "apple", "apron",
        "arrow", "aspen", "atlas", "attic", "award", "bacon", "badge", "bagel", "baker", "bamboo", "banjo", "barn",
        "basil", "basin", "beach", "beard", "berry", "bike", "bingo", "birch", "bison", "blade", "blank", "bloom",
        "board", "boat", "bonus", "boots", "bread", "brick", "bride", "brook", "broom", "brush", "bucket", "buddy",
        "bugle", "cabin", "cable", "cactus", "camel", "candy", "canoe", "canvas", "cargo", "carrot", "castle",
        "cedar", "chair", "chalk", "charm", "cheese", "cherry", "chess", "chief", "chili", "cider", "cinema",
        "circle", "clam", "cliff", "clock", "cloud", "clover", "coast", "cobra", "cocoa", "comet", "coral", "cotton",
        "cousin", "crab", "crane", "crayon", "cream", "creek", "crown", "cube", "cupid", "curry", "daisy", "dance",
        "delta", "denim", "desk", "diary", "dingo", "donut", "dragon", "drum", "eagle", "easel", "echo", "elbow",
        "elder", "ember", "empty", "engine", "falcon", "fern", "fiddle", "field", "finch", "flag", "flame", "flute",
        "focus", "forest", "fossil", "fox", "frame", "frog", "fruit", "galaxy", "garden", "garlic", "gecko", "giant",
        "ginger", "glove", "goat", "golf", "goose", "grape", "gravel", "guitar", "hammer", "harbor", "hazel",
        "helmet", "heron", "honey", "hotel", "igloo", "index", "iris", "island", "ivory", "jacket", "jaguar",
        "jelly", "jewel", "juice", "kayak", "kettle", "kiwi", "koala", "ladder", "lake", "lamp", "lemon", "lilac",
        "lime", "linen", "lion", "lizard", "llama", "lobby", "lotus", "magnet", "mango", "maple", "marble", "meadow",
        "melon", "metal", "mint", "mirror", "mitten", "monkey", "moose", "motor", "muffin", "nectar", "needle",
        "nest", "noodle", "nutmeg", "oasis", "ocean", "olive", "onion", "orbit", "otter", "owl", "paddle", "panda",
        "paper", "parrot", "pasta", "peach", "pearl", "pebble", "pencil", "pepper", "piano", "pickle", "pigeon",
        "pillow", "pilot", "plum", "pocket", "pony", "poppy", "potato", "prism", "pupil", "puzzle", "quail",
        "quartz", "quilt", "rabbit", "radar", "radio", "raisin", "raven", "ribbon", "river", "robin", "rocket",
        "rose", "ruby", "saddle", "salad", "salmon", "sandal", "satin", "scarf", "shell", "shovel", "silver",
        "sketch", "sloth", "snail", "socket", "sofa", "spider", "spoon", "spruce", "squid", "statue", "stone",
        "storm", "sugar"
    ]
}
