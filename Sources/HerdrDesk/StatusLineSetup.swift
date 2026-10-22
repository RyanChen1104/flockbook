import HerdrKit
import Foundation
import Observation

/// Settings > Agents > "Show Claude Code status line" (`ClaudeStatusLineSetting`). Claude Code's settings file changes
/// only when the owner switches it on or off. The wrapper ships inside the app (Contents/MacOS/flockbook-statusline)
/// and saves its records in the app's own Application Support folder.
@MainActor @Observable final class StatusLineSetup {
    /// `moved`: the settings run an older copy's wrapper (the app moved since); On fixes the path.
    enum State: Equatable { case off, on, replaced, moved, problem(String) }

    let settingsFile: URL
    let wrapperURL: URL
    let folder: StatusLineFolder
    private(set) var state: State = .off
    private(set) var lastBackup: URL?

    /// Snapshots: a fixed state; nothing is read or written.
    private let previewState: State?

    init(settingsFile: URL, wrapperURL: URL, dir: URL, preview: State? = nil) {
        self.settingsFile = settingsFile; self.wrapperURL = wrapperURL; folder = .init(url: dir); previewState = preview
        if let preview { state = preview }
    }

    /// The live paths with a fixed state (shown with "~", never read or written).
    static func preview(_ state: State) -> StatusLineSetup {
        StatusLineSetup(settingsFile: live.settingsFile, wrapperURL: live.wrapperURL, dir: live.folder.url, preview: state)
    }

    /// Snapshots and views without the live switch: off, never read or written.
    static let previewOff = preview(.off)

    static let live: StatusLineSetup = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        return StatusLineSetup(settingsFile: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"),
                               wrapperURL: exe.appendingPathComponent("flockbook-statusline"),
                               dir: support.appendingPathComponent("Flockbook/statusline", isDirectory: true))
    }()

    var command: String { ClaudeStatusLineSetting.command(wrapper: wrapperURL.path, dir: folder.url.path) }

    /// Reads the settings file (read-only).
    func refresh() {
        guard previewState == nil else { return }
        do {
            let s = try ClaudeSettingsHook.read(settingsFile)
            let now: State = switch ClaudeStatusLineSetting.state(s, command: command, wasOn: folder.wasOn) {
            case .on: .on
            case .moved: .moved
            case .off: .off
            case .replaced: .replaced
            }
            if now != state { state = now }
        } catch { state = .problem("\(error)") }
        checked = Date()
    }

    @ObservationIgnored private var checked = Date.distantPast
    /// `refresh` at most every few seconds: the panes ask on each read, and `/statusline` may change the file any time.
    func refreshIfStale() {
        if Date().timeIntervalSince(checked) > 5 { refresh() }
    }

    /// The owner switched it on (or on again after `/statusline` replaced ours): their statusLine is kept and ours
    /// goes in its place (the file backed up first). Moved: only the path changes.
    func turnOn() {
        guard previewState == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: wrapperURL.path) else {
            state = .problem("flockbook-statusline is missing next to the app"); return
        }
        do {
            lastBackup = try ClaudeStatusLineSetting.apply(on: true, file: settingsFile, command: command, folder: folder) ?? lastBackup
            refresh()
        } catch { state = .problem("\(error)") }
    }

    /// The owner switched it off: their own statusLine goes back.
    func turnOff() {
        guard previewState == nil else { return }
        do {
            if state == .replaced { folder.forgetOriginal() }   // theirs is in already; only our note goes
            else { lastBackup = try ClaudeStatusLineSetting.apply(on: false, file: settingsFile, command: command, folder: folder) ?? lastBackup }
            refresh()
        } catch { state = .problem("\(error)") }
    }

    /// What the owner's statusLine is now, for the sheet.
    var originalSummary: String? {
        guard previewState == nil else { return "sh ~/.claude/statusline.sh" }
        return state == .on || state == .moved ? folder.originalCommand() : currentCommand
    }

    /// The statusLine command in the settings file now.
    var currentCommand: String? {
        guard previewState == nil else { return state == .moved ? "'/Volumes/Flockbook/Flockbook.app/Contents/MacOS/flockbook-statusline' --dir '…'" : nil }
        return (try? ClaudeSettingsHook.read(settingsFile)).flatMap { ($0["statusLine"] as? [String: Any])?["command"] as? String }
    }

    /// A session's saved line, while ours is on.
    func record(session: String) -> StatusLineRecord? {
        if let r = StatusLineProbe.injected[session] { return r }   // offscreen shots only (empty in the app)
        guard previewState == nil else { return nil }
        refreshIfStale()
        guard state == .on || state == .moved else { return nil }
        return folder.record(session: session)
    }
}

/// Offscreen shots: status lines per session, without the wrapper.
@MainActor enum StatusLineProbe {
    static var injected: [String: StatusLineRecord] = [:]
}
