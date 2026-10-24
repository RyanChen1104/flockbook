import HerdrKit
import Foundation
import Observation

/// Settings > Agents > "Show Claude Code status line" (`ClaudeStatusLineSetting`) and "Show Grok Build status line"
/// (`GrokStatusLineSetting`, `agent` "grok"). The agent's settings file changes only when the owner switches it on or
/// off. On this Mac the wrapper ships inside the app (Contents/MacOS/flockbook-statusline) and saves its records in the
/// app's own Application Support folder, one folder per agent. For a remote herdr Claude Code runs on the host: a POSIX
/// sh wrapper goes into the host's ~/.config/flockbook, ours into the host's ~/.claude/settings.json, and the saved
/// lines are read from there while a pane shows one (`RemoteStatusLine`). Grok's switch acts on this Mac only.
@MainActor @Observable final class StatusLineSetup {
    /// `moved`: the settings run an older copy's wrapper (the app moved since); On fixes the path.
    enum State: Equatable { case off, on, replaced, moved, problem(String) }

    /// "claude" or "grok".
    let agent: String
    let settingsFile: URL
    let wrapperURL: URL
    let folder: StatusLineFolder
    /// nil: this Mac.
    let remote: RemoteHost?
    private(set) var state: State = .off
    private(set) var lastBackup: URL?
    /// The host's paths, once its home folder is known (remote only).
    private(set) var remotePaths: RemoteHookPaths?
    /// The host's own command and its statusLine command now, from the last read (remote only).
    private var remoteOwn: String?
    private var remoteCurrent: String?
    /// A remote read or write is running.
    private(set) var busy = false

    /// Snapshots: a fixed state; nothing is read or written.
    private let previewState: State?
    private let site: RemoteHookSite?
    /// The host's saved lines per session, read at most every 2 s while a pane asks (remote only).
    private let lines: RemotePoll<String, StatusLineRecord>?

    init(agent: String = "claude", settingsFile: URL, wrapperURL: URL, dir: URL, remote: RemoteHost? = nil, preview: State? = nil) {
        self.agent = agent; self.settingsFile = settingsFile; self.wrapperURL = wrapperURL; folder = .init(url: dir); previewState = preview
        self.remote = remote
        let site = remote.map { RemoteHookSite(host: $0) }
        self.site = site
        lines = site.map { site in
            RemotePoll<String, StatusLineRecord>(every: 2) { session in await site.statusLine()?.record(session: session) }
        }
        if let preview { state = preview }
    }

    /// The live paths with a fixed state (shown with "~", never read or written).
    static func preview(_ state: State, agent: String = "claude") -> StatusLineSetup {
        let l = live(agent: agent) ?? live
        return StatusLineSetup(agent: l.agent, settingsFile: l.settingsFile, wrapperURL: l.wrapperURL, dir: l.folder.url, preview: state)
    }

    /// Snapshots and views without the live switch: off, never read or written.
    static let previewOff = preview(.off)
    static let grokPreviewOff = preview(.off, agent: "grok")

    private static func make(agent: String, settings: String, folder: String, remote: RemoteHost?) -> StatusLineSetup {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        return StatusLineSetup(agent: agent, settingsFile: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(settings),
                               wrapperURL: exe.appendingPathComponent("flockbook-statusline"),
                               dir: support.appendingPathComponent(folder, isDirectory: true),
                               remote: remote)
    }

    static let live = make(agent: "claude", settings: ".claude/settings.json", folder: "Flockbook/statusline", remote: ClaudeHookSetup.launchRemote)
    static let grokLive = make(agent: "grok", settings: ".grok/config.toml", folder: "Flockbook/statusline-grok", remote: nil)

    /// The live switch for an agent kind; nil: an agent without one.
    static func live(agent: String?) -> StatusLineSetup? {
        switch agent {
        case "claude": live
        case "grok": grokLive
        default: nil
        }
    }

    var isGrok: Bool { agent == "grok" }
    /// The agent's name in Settings.
    var agentName: String { isGrok ? "Grok Build" : "Claude Code" }

    /// Grok's config.toml as text; "" when there is none.
    private func grokText() throws -> String {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return "" }
        return try String(contentsOf: settingsFile, encoding: .utf8)
    }

    /// Which machine's agent this acts on, for Settings.
    var machine: String { remote.map { "the host \($0.label)" } ?? "this Mac" }

    var command: String {
        if remote != nil {
            guard let p = remotePaths else { return ClaudeStatusLineSetting.command(wrapper: "~/.config/flockbook/statusline/flockbook-statusline", dir: "~/.config/flockbook/statusline/lines") }
            return ClaudeStatusLineSetting.command(wrapper: p.statusWrapper, dir: p.statusDir)
        }
        return ClaudeStatusLineSetting.command(wrapper: wrapperURL.path, dir: folder.url.path)
    }

    /// The home folder shown as "~" in the sheet: the host's for a remote herdr.
    var home: String { remote == nil ? FileManager.default.homeDirectoryForCurrentUser.path : remotePaths?.home ?? "~" }
    /// The settings file and the wrapper, as Settings shows them ("~" for the home folder, and the machine).
    var settingsLabel: String { remote == nil ? ClaudeHookSetup.tilde(settingsFile.path) : "~/.claude/settings.json on \(remote!.label)" }
    var wrapperLabel: String {
        guard let remote else { return ClaudeHookSetup.tilde(wrapperURL.path) }
        return "~/.config/flockbook/statusline/flockbook-statusline on \(remote.label)"
    }

    /// Reads the settings file (read-only). Remote: in the background; the state follows when the host answers.
    func refresh() {
        guard previewState == nil else { return }
        checked = Date()
        if let site {
            guard !busy else { return }
            busy = true
            Task {
                defer { busy = false }
                guard let sl = await site.statusLine() else { state = .problem("\(site.host.label) did not answer"); return }
                remotePaths = sl.paths
                do {
                    set(try await sl.state())
                    remoteOwn = await sl.ownCommand()
                    remoteCurrent = await sl.currentCommand()
                } catch { state = .problem("\(error)") }
                if checked.timeIntervalSince(cleaned) > 24 * 3600 { cleaned = checked; await sl.clean() }
            }
            return
        }
        do {
            let now: State
            if isGrok {
                now = switch try GrokStatusLineSetting.state(try grokText(), command: command, wasOn: folder.wasOn) {
                case .on: .on
                case .moved: .moved
                case .off: .off
                case .replaced: .replaced
                }
                if now != state { state = now }
            } else {
                set(ClaudeStatusLineSetting.state(try ClaudeSettingsHook.read(settingsFile), command: command, wasOn: folder.wasOn))
            }
        } catch { state = .problem("\(error)") }
        if checked.timeIntervalSince(cleaned) > 24 * 3600 {
            // Old records go once a day, the first time at start.
            cleaned = checked
            let f = folder
            Task.detached(priority: .utility) { f.clean() }
        }
    }

    private func set(_ s: ClaudeStatusLineSetting.State) {
        let now: State = switch s {
        case .on: .on
        case .moved: .moved
        case .off: .off
        case .replaced: .replaced
        }
        if now != state { state = now }
    }

    @ObservationIgnored private var cleaned = Date.distantPast

    @ObservationIgnored private var checked = Date.distantPast
    /// `refresh` at most every few seconds: the panes ask on each read, and `/statusline` may change the file any time.
    /// A host's file is read every 30 s (each read is a round trip).
    func refreshIfStale() {
        if Date().timeIntervalSince(checked) > (remote == nil ? 5 : 30) { refresh() }
    }

    /// The owner switched it on (or on again after `/statusline` replaced ours): their statusLine is kept and ours
    /// goes in its place (the file backed up first). Moved: only the path changes.
    func turnOn() {
        guard previewState == nil else { return }
        if site != nil { remoteApply(on: true); return }
        guard FileManager.default.isExecutableFile(atPath: wrapperURL.path) else {
            state = .problem("flockbook-statusline is missing next to the app"); return
        }
        do {
            lastBackup = try (isGrok ? GrokStatusLineSetting.apply(on: true, file: settingsFile, command: command, folder: folder)
                                     : ClaudeStatusLineSetting.apply(on: true, file: settingsFile, command: command, folder: folder)) ?? lastBackup
            refresh()
        } catch { state = .problem("\(error)") }
    }

    /// The owner switched it off: their own statusLine goes back.
    func turnOff() {
        guard previewState == nil else { return }
        if site != nil { remoteApply(on: false); return }
        refresh()   // the state now: a file that cannot be read is a problem, not "replaced"
        do {
            if state == .replaced { folder.forgetOriginal(); folder.clean() }   // theirs is in already; only our note goes
            else {
                lastBackup = try (isGrok ? GrokStatusLineSetting.apply(on: false, file: settingsFile, command: command, folder: folder)
                                         : ClaudeStatusLineSetting.apply(on: false, file: settingsFile, command: command, folder: folder)) ?? lastBackup
            }
            refresh()
        } catch { state = .problem("\(error)") }
    }

    /// On or off on the host. The backup stays on the host, next to its settings file.
    private func remoteApply(on: Bool) {
        guard let site, !busy else { return }
        busy = true
        let replaced = state == .replaced
        Task {
            defer { busy = false; lines?.reset() }
            guard let sl = await site.statusLine() else { state = .problem("\(site.host.label) did not answer"); return }
            remotePaths = sl.paths
            do {
                if !on && replaced { await sl.forget() } else { try await sl.apply(on: on) }
                set(try await sl.state())
                remoteOwn = await sl.ownCommand()
                remoteCurrent = await sl.currentCommand()
                checked = Date()
            } catch { state = .problem("\(error)") }
        }
    }

    /// What the owner's statusLine is now, for the sheet.
    var originalSummary: String? {
        guard previewState == nil else { return isGrok ? "built-in: cwd, model, context" : "sh ~/.claude/statusline.sh" }
        if remote != nil { return state == .on || state == .moved ? remoteOwn : remoteCurrent }
        if isGrok, state == .on || state == .moved, let o = folder.original(), o["type"] as? String == "builtin" {
            return "built-in: " + (o["items"] as? [String] ?? GrokStatusLineSetting.defaultItems).joined(separator: ", ")
        }
        return state == .on || state == .moved ? folder.originalCommand() : currentCommand
    }

    /// Grok: the `[ui.status_line]` table now and after the switch, read-only (nil: none, or unreadable).
    func grokTables(on: Bool) -> (now: String?, after: String?) {
        guard previewState == nil else {
            let ours = "[ui.status_line]\ntype = \"command\"\ncommand = \"\(command)\""
            let theirs = "[ui.status_line]\ntype = \"builtin\""
            return on ? (ours, theirs) : (theirs, ours)
        }
        guard let text = try? grokText() else { return (nil, nil) }
        let after = on ? (try? GrokStatusLineSetting.disabling(text, command: command, original: folder.original())) ?? nil
                       : (try? GrokStatusLineSetting.enabling(text, command: command))?.text
        return (GrokStatusLineSetting.tableText(text), after.flatMap(GrokStatusLineSetting.tableText))
    }

    /// The statusLine command in the settings file now.
    var currentCommand: String? {
        guard previewState == nil else { return state == .moved ? "'/Volumes/Flockbook/Flockbook.app/Contents/MacOS/flockbook-statusline' --dir '…'" : nil }
        if remote != nil { return remoteCurrent }
        if isGrok { return (try? grokText()).flatMap(GrokStatusLineSetting.currentCommand) }
        return (try? ClaudeSettingsHook.read(settingsFile)).flatMap { ($0["statusLine"] as? [String: Any])?["command"] as? String }
    }

    /// A session's saved line, while ours is on. Remote: the last line read from the host (a read starts when it is
    /// over 2 s old), so only panes that ask cause reads.
    func record(session: String) -> StatusLineRecord? {
        if let r = StatusLineProbe.injected[session] { return r }   // offscreen shots only (empty in the app)
        guard previewState == nil else { return nil }
        refreshIfStale()
        guard state == .on || state == .moved else { return nil }
        if let lines { return lines.value(session) }
        return folder.record(session: session)
    }
}

/// Offscreen shots: status lines per session, without the wrapper.
@MainActor enum StatusLineProbe {
    static var injected: [String: StatusLineRecord] = [:]
}
