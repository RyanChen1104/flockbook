import HerdrKit
import Foundation
import Observation

/// Settings > Remote access > "Answer Claude questions from the phone": the AskUserQuestion hook
/// (`ClaudeQuestionHook`). On this Mac the app writes the script and reads its records in its own Application Support
/// folder. For a remote herdr Claude Code runs on the host, so everything goes there (`RemoteClaudeHook`): the script
/// and its records in the host's ~/.config/flockbook, our entry in the host's ~/.claude/settings.json, the records
/// read through short commands while a question is looked for. Claude Code's settings file changes only when the
/// owner clicks Install or Uninstall.
@MainActor @Observable final class ClaudeHookSetup {
    enum State: Equatable { case off, on, problem(String) }

    let settingsFile: URL
    let scriptURL: URL
    let folder: ClaudeQuestionHook.Folder
    /// nil: this Mac.
    let remote: RemoteHost?
    private(set) var state: State = .off
    private(set) var lastBackup: URL?
    /// The host's paths, once its home folder is known (remote only).
    private(set) var remotePaths: RemoteHookPaths?
    /// A remote read or write is running.
    private(set) var busy = false

    /// Snapshots: a fixed state; nothing is read or written.
    private let previewState: State?
    private let site: RemoteHookSite?
    /// The host's records, read at most every 2 s while the hub asks (remote only).
    private let records: RemotePoll<String, [ClaudeQuestionHook.Record]>?

    init(settingsFile: URL, scriptURL: URL, recordsDir: URL, remote: RemoteHost? = nil, preview: State? = nil) {
        self.settingsFile = settingsFile; self.scriptURL = scriptURL; folder = .init(url: recordsDir); previewState = preview
        self.remote = remote
        let site = remote.map { RemoteHookSite(host: $0) }
        self.site = site
        records = site.map { site in
            RemotePoll<String, [ClaudeQuestionHook.Record]>(every: 2) { _ in await site.hook()?.records() }
        }
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
                               recordsDir: dir.appendingPathComponent("questions", isDirectory: true),
                               remote: launchRemote)
    }()

    /// The host of the herdr session the app's store reads (`store.session.remote`); nil: this Mac. Set once at launch,
    /// before `live` is first used (`HerdrDeskApp`); previews and snapshots leave it nil.
    static var launchRemote: RemoteHost?

    /// Which machine's Claude Code this acts on, for Settings.
    var machine: String { remote.map { "the host \($0.label)" } ?? "this Mac" }

    var command: String {
        if remote != nil {
            return ClaudeSettingsHook.command(scriptPath: remotePaths?.hookScript ?? "~/.config/flockbook/claude-hook/ask-user-question.sh")
        }
        return ClaudeSettingsHook.command(scriptPath: scriptURL.path)
    }
    var preview: String { ClaudeSettingsHook.preview(command: command) }

    /// The settings file and the script, as Settings shows them ("~" for the home folder, and the machine).
    var settingsLabel: String { remote == nil ? Self.tilde(settingsFile.path) : "~/.claude/settings.json on \(remote!.label)" }
    var scriptLabel: String {
        guard let remote else { return Self.tilde(scriptURL.path) }
        return "~/.config/flockbook/claude-hook/ask-user-question.sh on \(remote.label)"
    }
    static func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    /// Reads the settings file (read-only). Remote: in the background; the state follows when the host answers.
    func refresh() {
        guard previewState == nil else { return }
        if let site {
            guard !busy else { return }
            busy = true
            Task {
                defer { busy = false }
                guard let hook = await site.hook() else { state = .problem("\(site.host.label) did not answer"); return }
                remotePaths = hook.paths
                do { state = try await hook.installed() ? .on : .off } catch { state = .problem("\(error)") }
            }
            return
        }
        do { state = ClaudeSettingsHook.installed(try ClaudeSettingsHook.read(settingsFile), command: command) ? .on : .off }
        catch { state = .problem("\(error)") }
    }

    /// The owner clicked Install: the script first, then our entry in the settings file (backed up).
    func install() {
        guard previewState == nil else { return }
        if site != nil { remoteApply(add: true); return }
        do {
            try folder.writeScript(to: scriptURL)
            lastBackup = try ClaudeSettingsHook.apply(add: true, file: settingsFile, command: command) ?? lastBackup
            refresh()
        } catch { state = .problem("\(error)") }
    }

    /// The owner clicked Uninstall: only our entry leaves the settings file.
    func uninstall() {
        guard previewState == nil else { return }
        if site != nil { remoteApply(add: false); return }
        do {
            lastBackup = try ClaudeSettingsHook.apply(add: false, file: settingsFile, command: command) ?? lastBackup
            refresh()
        } catch { state = .problem("\(error)") }
    }

    /// Install or Uninstall on the host. The backup stays on the host, next to its settings file.
    private func remoteApply(add: Bool) {
        guard let site, !busy else { return }
        busy = true
        Task {
            defer { busy = false; records?.reset() }
            guard let hook = await site.hook() else { state = .problem("\(site.host.label) did not answer"); return }
            remotePaths = hook.paths
            do {
                if add { try await hook.install() } else { try await hook.uninstall() }
                state = try await hook.installed() ? .on : .off
            } catch { state = .problem("\(error)") }
        }
    }

    /// The newest saved call for an agent session. Remote: the last records read from the host (a read starts when
    /// they are over 2 s old), so a new question shows up on the next look.
    nonisolated func question(session: String) -> QuestionRequest? {
        if let records {
            return records.value("records").flatMap { ClaudeQuestionHook.newest($0, session: session, now: Date()) }
        }
        return ClaudeQuestionHook.newest(folder.records(), session: session, now: Date())
    }
}
