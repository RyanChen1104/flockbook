import HerdrKit
import Foundation

/// Sends a composer message to a pane.
/// Plain text: one call, text + Enter. With a pasted image path: agents such as Claude Code turn the path into an
/// attachment asynchronously and drop an Enter that arrives meanwhile. So the text goes first, the screen is polled
/// (read-only) until the attachment shows up, and only then Enter is sent.
enum MessageSender {
    static func hasImagePath(_ text: String) -> Bool { text.contains(PasteImages.directory.path) }

    /// False when herdr did not take the message (not connected, pane gone): the composer gives the text back.
    @discardableResult
    static func send(_ text: String, to paneId: String, client: HerdrClient,
                     waitFor marker: String = "[Image", maxWait: Duration = .seconds(2)) async -> Bool {
        guard hasImagePath(text) else {
            do { try await client.send(text: text, to: paneId); return true } catch { return false }
        }
        do {
            try await client.sendKeys(Array(text.utf8), to: paneId)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: maxWait)
            while clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                if await screen(paneId, client).contains(marker) { break }
            }
            try await client.sendNamedKeys(["Enter"], to: paneId)
            // Input still holds the message (Enter was eaten): press once more.
            try? await Task.sleep(for: .milliseconds(500))
            let tail = (await screen(paneId, client)).split(separator: "\n", omittingEmptySubsequences: true).suffix(6).joined(separator: "\n")
            if tail.contains(marker) { try await client.sendNamedKeys(["Enter"], to: paneId) }
            return true
        } catch { return false }
    }

    private static func screen(_ paneId: String, _ client: HerdrClient) async -> String {
        (try? await client.readScrollback(paneId: paneId, lines: 40, ansi: false).text) ?? ""
    }
}
