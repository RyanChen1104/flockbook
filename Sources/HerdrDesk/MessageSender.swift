import HerdrKit
import Foundation

/// Sends a composer message to a pane.
/// Plain text: one call, text + Enter. With image files of ours (`ImagePaste.plan`): the text goes through the same
/// text call without Enter (a newline stays in the agent's input), each path as a bracketed paste (typed, Claude Code
/// keeps it as text). Claude Code and Codex turn a pasted path into `[Image #n]` asynchronously and drop an Enter
/// that arrives meanwhile, so the screen is polled (read-only) until the new markers show in the input, and only
/// then Enter is sent. No new marker in time, or the screen cannot be read: no Enter (the message stays in the input).
@MainActor enum MessageSender {
    static func hasImagePath(_ text: String) -> Bool {
        ImagePaste.plan(text, directory: PasteImages.directory.path).contains { if case .paste = $0 { true } else { false } }
    }

    /// True when the message was submitted. False when herdr did not take it, the gate said no, or the image did
    /// not show up in time (then the text may wait in the agent's input, not submitted).
    /// `kind`: the pane's agent kind (which agents show an image marker). `gate` (a remote device): asked before
    /// every step and right before each Enter, with the new markers re-read last (`HerdrClient.passes`); herdr has
    /// no compare-and-send, so the moment between that read and the key stays.
    @discardableResult
    static func send(_ text: String, to paneId: String, client: HerdrClient, kind: String?,
                     gate: KeyGate? = nil, maxWait: Duration = .seconds(5)) async -> Bool {
        let steps = ImagePaste.plan(text, directory: PasteImages.directory.path)
        let images = steps.filter { if case .paste = $0 { true } else { false } }.count
        guard images > 0 else {
            guard await client.passes(gate, paneId: paneId) else { return false }
            do { try await client.send(text: text, to: paneId); return true } catch { return false }
        }
        let wait = kind.map(ImagePaste.waitsForMarker) ?? false
        let k = kind ?? ""
        func markers() async -> Int? { (try? await client.visibleText(paneId: paneId)).map { ImagePaste.inputMarkers($0, kind: k) } }
        do {
            // Markers already in the input do not count: only new ones after our paste.
            var target = 0
            if wait { guard let n = await markers() else { return false }; target = n + images }
            for step in steps {
                guard await client.passes(gate, paneId: paneId) else { return false }
                switch step {
                case .input(let t): try await client.type(text: t, to: paneId)
                case .paste(let path): try await client.sendKeys(Array(ImagePaste.paste(path).utf8), to: paneId)
                }
            }
            if wait {
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: maxWait)
                var shown = false
                while clock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let n = await markers() else { return false }
                    if n >= target { shown = true; break }
                }
                guard shown else { return false }
            }
            // Right before Enter: the same agent, the new markers still in the input (read last), input allowed.
            let t = target
            let check: @Sendable (String) -> Bool = { ImagePaste.inputMarkers($0, kind: k) >= t }
            let ready = wait ? check : nil
            guard await client.passes(gate, paneId: paneId, screen: ready) else { return false }
            try await client.sendNamedKeys(["Enter"], to: paneId)
            // The input still holds the new markers (Enter was eaten): press once more, gated the same way.
            if wait {
                try? await Task.sleep(for: .milliseconds(500))
                if let n = await markers(), n >= target, await client.passes(gate, paneId: paneId, screen: ready) {
                    try await client.sendNamedKeys(["Enter"], to: paneId)
                }
            }
            return true
        } catch { return false }
    }
}
