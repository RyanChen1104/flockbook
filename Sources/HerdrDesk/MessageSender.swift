import HerdrKit
import Foundation

/// The composer's send (`MessageSend`) with the app's image folder.
@MainActor enum MessageSender {
    static func hasImagePath(_ text: String) -> Bool {
        ImagePaste.plan(text, directory: PasteImages.directory.path).contains { if case .paste = $0 { true } else { false } }
    }

    /// True when the message was submitted (see `MessageSend.send`).
    @discardableResult
    static func send(_ text: String, to paneId: String, client: HerdrClient, kind: String?,
                     gate: KeyGate? = nil, maxWait: Duration = .seconds(5)) async -> Bool {
        await MessageSend.send(text, to: paneId, client: client, kind: kind, directory: PasteImages.directory.path, gate: gate, maxWait: maxWait)
    }
}
