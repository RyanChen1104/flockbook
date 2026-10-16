import Foundation

/// Text pulled back from an agent's queue (`QueuePull`). Kept from before the first Ctrl-U until the composer of the
/// device that pulled it has it, so a failed read, a lost connection or a quit never loses it.
public struct PulledText: Codable, Hashable, Sendable {
    public var id: String
    public var pane: String
    /// Who pulled it: `PulledText.mac`, or a hub device id. Only that one gets it.
    public var device: String
    public var text: String
    public var at: Date
    public init(id: String = UUID().uuidString, pane: String, device: String, text: String, at: Date = Date()) {
        self.id = id; self.pane = pane; self.device = device; self.text = text; self.at = at
    }
    /// The Mac app's own composer.
    public static let mac = "mac"
}

/// Pulled texts not in a composer yet. `keep` before the Ctrl-U; `take` once the composer has the text.
@MainActor public class MemoryPulledStore {
    public private(set) var all: [PulledText] = []
    public init() {}

    /// Keeps `p`. False: it could not be saved (then nothing must clear the agent's input box).
    public func keep(_ p: PulledText) -> Bool {
        all.append(p)
        guard save() else { all.removeLast(); return false }
        return true
    }

    /// The text `id` of `device`, removed: its composer has it now. Nil: not kept (or taken already).
    public func take(id: String, device: String) -> PulledText? {
        guard let i = all.firstIndex(where: { $0.id == id && $0.device == device }) else { return nil }
        let p = all.remove(at: i)
        _ = save()   // not saved: a restart brings it back once more (twice in a composer, never lost)
        return p
    }

    /// The device's texts not taken yet, oldest first.
    public func pending(device: String) -> [PulledText] { all.filter { $0.device == device } }

    func load(_ ps: [PulledText]) { all = ps }
    /// Saves; false when that failed.
    func save() -> Bool { true }
}

/// Pulled texts in a JSON file, mode 600 (it holds what the owner typed).
@MainActor public final class FilePulledStore: MemoryPulledStore {
    public let url: URL
    public init(url: URL) {
        self.url = url
        super.init()
        if let data = try? Data(contentsOf: url) {
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            load((try? d.decode([PulledText].self, from: data)) ?? [])
        }
    }
    override func save() -> Bool {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? PrivateFile.write(try e.encode(all), to: url)) != nil
    }
}
