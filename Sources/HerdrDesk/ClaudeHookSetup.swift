import HerdrKit
import Foundation
import Observation

/// Settings > Remote access > "Answer Claude questions from the phone": the AskUserQuestion hook
/// (`ClaudeQuestionHook`). The app writes the script and reads its records in its own Application Support folder.
/// Claude Code's settings file changes only when the owner clicks Install or Uninstall.
@MainActor @Observable final class ClaudeHookSetup {
    enum State: Equatable { case off, on, problem(String) }

    let settingsFile: URL
    let scriptURL: URL
    let folder: ClaudeQuestionHook.Folder
    private(set) var state: State = .off
    private(set) var lastBackup: URL?

    /// Snapshots: a fixed state; nothing is read or written.
    private let previewState: State?

    init(settingsFile: URL, scriptURL: URL, recordsDir: URL, preview: State? = nil) {
        self.settingsFile = settingsFile; self.scriptURL = scriptURL; folder = .init(url: recordsDir); previewState = preview
        if let preview { state = preview }
    }

    /// The live paths with a fixed state (shown with "~", never read or written).
    static func preview(_ state: State) -> ClaudeHookSetup {
        ClaudeHookSetup(settingsFile: live.settingsFile, scriptURL: live.scriptURL, recordsDir: live.folder.url, preview: state)
    }

    static let live: ClaudeHookSetup = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Flockbook/claude-hook", isDirectory: true)
        return ClaudeHookSetup(settingsFile: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"),
                               scriptURL: dir.appendingPathComponent("ask-user-question.sh"),
                               recordsDir: dir.appendingPathComponent("questions", isDirectory: true))
    }()

    var command: String { ClaudeSettingsHook.command(scriptPath: scriptURL.path) }
    var preview: String { ClaudeSettingsHook.preview(command: command) }

    /// Reads the settings file (read-only).
    func refresh() {
        guard previewState == nil else { return }
        do { state = ClaudeSettingsHook.installed(try ClaudeSettingsHook.read(settingsFile), command: command) ? .on : .off }
        catch { state = .problem("\(error)") }
    }

    /// The owner clicked Install: the script first, then our entry in the settings file (backed up).
    func install() {
        guard previewState == nil else { return }
        do {
            try folder.writeScript(to: scriptURL)
            lastBackup = try ClaudeSettingsHook.apply(add: true, file: settingsFile, command: command) ?? lastBackup
            refresh()
        } catch { state = .problem("\(error)") }
    }

    /// The owner clicked Uninstall: only our entry leaves the settings file.
    func uninstall() {
        guard previewState == nil else { return }
        do {
            lastBackup = try ClaudeSettingsHook.apply(add: false, file: settingsFile, command: command) ?? lastBackup
            refresh()
        } catch { state = .problem("\(error)") }
    }

    /// The newest saved call for an agent session.
    nonisolated func question(session: String) -> QuestionRequest? {
        ClaudeQuestionHook.newest(folder.records(), session: session, now: Date())
    }
}
