import Foundation

/// Sends a composer message to a pane (the Mac composer and the remote hub; `MessageSender` in the app).
/// Plain text: one call, text + Enter. With image files of ours (`ImagePaste.plan`): the text goes through the same
/// text call without Enter (a newline stays in the agent's input), each path as a bracketed paste (typed, Claude Code
/// keeps it as text). Claude Code, Codex and Grok Build turn a pasted path into `[Image #n]` asynchronously and drop an Enter
/// that arrives meanwhile, so the screen is polled (read-only) until the new markers show in the input, and only
/// then Enter is sent. No new marker in time, or the screen cannot be read: no Enter (the message stays in the input).
@MainActor public enum MessageSend {
    /// True when the message was submitted. False when herdr did not take it, the gate said no, or the image did
    /// not show up in time (then the text may wait in the agent's input, not submitted).
    /// `kind`: the pane's agent kind (which agents show an image marker). `gate` (a remote device): asked before
    /// every step and right before each Enter, with the new markers re-read last (`HerdrClient.passes`); herdr has
    /// no compare-and-send, so the moment between that read and the key stays.
    @discardableResult
    public static func send(_ text: String, to paneId: String, client: HerdrClient, kind: String?, directory: String,
                            gate: KeyGate? = nil, maxWait: Duration = .seconds(5)) async -> Bool {
        let steps = ImagePaste.plan(text, directory: directory)
        let images = steps.filter { if case .paste = $0 { true } else { false } }.count
        // `gate` (a remote device): before every step the agent is not blocked now and nothing on screen would take
        // the keys as a choice (a prompt, a question, any picker), read last.
        let atInput: @Sendable (String) -> Bool = { !Hub.screenTakesKeys($0) }
        let free: @Sendable (Agent) -> Bool = { $0.status != .blocked }
        guard images > 0 else {
            guard await client.passes(gate, paneId: paneId, screen: atInput, agent: free) else { return false }
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
                guard await client.passes(gate, paneId: paneId, screen: atInput, agent: free) else { return false }
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
            let ready: @Sendable (String) -> Bool = { atInput($0) && (!wait || ImagePaste.inputMarkers($0, kind: k) >= t) }
            guard await client.passes(gate, paneId: paneId, screen: ready, agent: free) else { return false }
            try await client.sendNamedKeys(["Enter"], to: paneId)
            // The input still holds the new markers (Enter was eaten): press once more, gated the same way. For a
            // paired device a refused or unreadable second check is a failure (the message may wait unsent).
            if wait {
                try? await Task.sleep(for: .milliseconds(500))
                guard let n = await markers() else { return gate == nil }
                if n >= target {
                    guard await client.passes(gate, paneId: paneId, screen: ready, agent: free) else { return false }
                    try await client.sendNamedKeys(["Enter"], to: paneId)
                }
            }
            return true
        } catch { return false }
    }
}
