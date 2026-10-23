import HerdrKit
import Foundation

/// The composer's send (`MessageSend`) with the app's image folder.
@MainActor enum MessageSender {
    static func hasImagePath(_ text: String) -> Bool {
        ImagePaste.plan(text, directory: PasteImages.directory.path).contains { if case .paste = $0 { true } else { false } }
    }

    /// Why a send of this message text failed, when there is more to say than "herdr did not take it" (an image that
    /// could not reach the host). Read once by the composer.
    private static var failures: [String: String] = [:]
    static func takeFailure(_ message: String) -> String? { failures.removeValue(forKey: message) }

    /// True when the message was submitted (see `MessageSend.send`). A remote session (`HerdrSession.remote`) copies
    /// each image to the host first (`RemoteUpload`) and pastes the host path.
    @discardableResult
    static func send(_ text: String, to paneId: String, client: HerdrClient, kind: String?,
                     gate: KeyGate? = nil, maxWait: Duration = .seconds(5)) async -> Bool {
        // `session` is an actor `let` of another module: read with await.
        guard let host = await client.session.remote else {
            return await MessageSend.send(text, to: paneId, client: client, kind: kind, directory: PasteImages.directory.path, gate: gate, maxWait: maxWait)
        }
        let steps: [ImagePaste.Step]
        do {
            steps = try await RemoteUpload(host: host).hostSteps(ImagePaste.plan(text, directory: PasteImages.directory.path))
        } catch {
            if failures.count > 20 { failures.removeAll() }
            failures[text] = "\(error)"
            return false
        }
        return await MessageSend.send(steps: steps, text: text, to: paneId, client: client, kind: kind, gate: gate, maxWait: maxWait)
    }
}
