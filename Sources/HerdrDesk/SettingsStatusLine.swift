import HerdrKit
import SwiftUI

/// Settings > Agents: "Show Claude Code status line" and "Show Grok Build status line". Off until the owner switches
/// it on; the sheet shows the exact change to the agent's settings file before anything is written. If the owner sets
/// another status line later (`/statusline`, or by hand), the row says so and asks them to switch it on again.
struct StatusLineRow: View {
    let setup: StatusLineSetup
    @State private var sheet = false

    var body: some View {
        let title = "Show \(setup.agentName) status line"
        SettingsGroup(setup.isGrok ? "Grok Build status line" : "Status line", note: note,
                      noteColor: isProblem ? .red : setup.state == .replaced || setup.state == .moved ? .orange : nil) {
            SettingsRow(title, value: value, valueColor: isProblem ? .red : nil) {
                if setup.state == .moved {
                    Button("Fix…") { sheet = true }
                }
                Toggle(title, isOn: Binding(get: { setup.state == .on || setup.state == .moved }, set: { _ in sheet = true }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            .settingsControl(setup.isGrok ? .grokStatusLine : .statusLine)
        }
        .sheet(isPresented: $sheet) { StatusLineSheet(setup: setup) }
        .onAppear { setup.refresh() }
    }

    private var value: String {
        switch setup.state {
        case .off: "Off"
        case .on: "On"
        case .replaced: "Changed"
        case .moved: "Needs fixing"
        case .problem: "Problem"
        }
    }

    private var isProblem: Bool { if case .problem = setup.state { true } else { false } }

    private var note: String {
        if setup.isGrok {
            return switch setup.state {
            case .off: "Off. Shows the line Grok draws under its prompt under each Grok composer, and on the phone."
            case .on: "On. Grok runs your own status line through Flockbook and shows it as before. Grok reads it at start: restart Grok to see a change."
            case .replaced: "Grok's status line was changed since in ~/.grok/config.toml. Switch this on again to show the new one."
            case .moved: "Needs fixing: Flockbook moved since this was switched on, and Grok still runs the old copy's command."
            case .problem(let m): "Could not change Grok's config.toml: \(m)."
            }
        }
        return switch setup.state {
        case .off: "Off. Shows the line Claude Code draws under its prompt under each Claude composer, and on the phone."
        case .on: "On. Claude Code runs your own status line through Flockbook, and shows it as before."
        case .replaced: "Claude Code's status line was changed since (for example with /statusline). Switch this on again to show the new one."
        case .moved: "Needs fixing: Flockbook moved since this was switched on, and Claude Code still runs the old copy's command."
        case .problem(let m): "Could not read Claude Code's settings: \(m)."
        }
    }
}

/// What switching on or off changes, shown before the owner clicks.
struct StatusLineSheet: View {
    let setup: StatusLineSetup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let moved = setup.state == .moved
        // Replaced (or the file unreadable): Stop is the way out; nothing of ours may be in the file.
        let stop = setup.state == .replaced || { if case .problem = setup.state { true } else { false } }()
        let on = setup.state == .on || moved
        let tilde = ClaudeHookSheet.tilde
        if setup.isGrok { GrokStatusLineSheet(setup: setup, on: on, moved: moved, stop: stop) } else {
        VStack(alignment: .leading, spacing: 12) {
            Text(moved ? "Fix the Status Line Command" : on ? "Stop Showing the Status Line" : "Show Claude Code's Status Line").font(.title3.weight(.semibold))
            Text(moved ? "Flockbook was moved since the status line was switched on. Claude Code still runs the command at the old place, which may be gone. Fix puts this copy's path in its place; your own status line and everything else stay."
                    : on ? "Turning this off puts your own status line back in the file below, as it was. Everything else stays."
                    : "Claude Code runs a status line command and shows its output under the prompt. Flockbook puts a small command of its own in that place: it runs your command with the same input, shows its output in Claude Code unchanged, and keeps a copy for Flockbook.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                if !on {
                    Label(setup.originalSummary.map { "Your command stays and still runs: \($0)" } ?? "You have no status line now. Flockbook shows the model, context and cost from Claude Code.",
                          systemImage: "terminal")
                    Label("Flockbook never runs your command itself. Only Claude Code does, as before. A command still running after 10 seconds is stopped.",
                          systemImage: "checkmark.shield")
                    Label("Only your user settings change. A status line in a project's .claude/settings.json or settings.local.json, or a managed one, still wins there; those sessions show no line in Flockbook.",
                          systemImage: "square.stack.3d.up")
                    Label("If you set another status line later (/statusline), Settings asks you to switch this on again.", systemImage: "arrow.triangle.2.circlepath")
                }
                if !on {
                    Label("Your status line's text is also sent to your paired phones while this is on.", systemImage: "iphone")
                }
                Label("A copy of the file is kept next to it before any change (the newest \(ClaudeSettingsHook.keptBackups)). The settings keep their content; their formatting and key order may change.",
                      systemImage: "doc.on.doc")
            }
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text("Changed in " + tilde(setup.settingsFile.path) + ":").font(.callout.weight(.medium))
            ScrollView([.horizontal, .vertical]) {
                Text(preview(on: on)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: moved ? 150 : 190)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            Text("Command: \(tilde(setup.wrapperURL.path))").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if stop {
                    Button("Stop") { setup.turnOff(); dismiss() }
                }
                if moved {
                    Button("Turn Off") { setup.turnOff(); dismiss() }
                    Button("Fix") { setup.turnOn(); dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(on ? "Turn Off" : "Turn On") {
                        if on { setup.turnOff() } else { setup.turnOn() }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        }
    }

    /// The statusLine before → after, with "~" for the home folder.
    private func preview(on: Bool) -> String {
        let ours: [String: Any] = ["type": "command", "command": setup.command]
        let theirs: [String: Any]? = setup.originalSummary.map { ["type": "command", "command": $0] }
        func json(_ v: Any?) -> String {
            guard let v else { return "(none)" }
            let d = (try? JSONSerialization.data(withJSONObject: ["statusLine": v], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: d, as: UTF8.self).replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        }
        if setup.state == .moved {
            return "Now:\n\(json(setup.currentCommand.map { ["type": "command", "command": $0] }))\n\nAfter:\n\(json(ours))"
        }
        return on ? "Now:\n\(json(ours))\n\nAfter:\n\(json(theirs))" : "Now:\n\(json(theirs))\n\nAfter:\n\(json(ours))"
    }
}

/// The sheet for Grok Build: the `[ui.status_line]` table of ~/.grok/config.toml now and after, read from the file.
struct GrokStatusLineSheet: View {
    let setup: StatusLineSetup
    let on: Bool, moved: Bool, stop: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let tilde = ClaudeHookSheet.tilde
        let tables = setup.grokTables(on: on && !moved)
        VStack(alignment: .leading, spacing: 12) {
            Text(moved ? "Fix the Status Line Command" : on ? "Stop Showing Grok's Status Line" : "Show Grok Build's Status Line").font(.title3.weight(.semibold))
            Text(moved ? "Flockbook was moved since the status line was switched on. Grok still runs the command at the old place, which may be gone. Fix puts this copy's path in its place; everything else stays."
                    : on ? "Turning this off puts your own [ui.status_line] back in the file below, exactly as it was. Everything else stays."
                    : "Grok runs a status line command and shows its output under the prompt. Flockbook puts a small command of its own in [ui.status_line]: it runs your command with the same input, or draws Grok's built-in line, shows it in Grok unchanged, and keeps a copy for Flockbook.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                if !on {
                    Label(setup.originalSummary.map { "Your status line stays and still shows: \($0)" } ?? "You have no status line now. Flockbook shows the model, context and cost from Grok.",
                          systemImage: "terminal")
                    Label("Flockbook never runs your command itself. Only Grok does, as before. A built-in line is drawn without Grok's colours.",
                          systemImage: "checkmark.shield")
                    Label("Only the [ui.status_line] table changes; the rest of the file stays as it is. Grok reads it at start: restart Grok to see the change.",
                          systemImage: "arrow.clockwise")
                    Label("Your status line's text is also sent to your paired phones while this is on.", systemImage: "iphone")
                }
                Label("A copy of the file is kept next to it before any change (the newest \(ClaudeSettingsHook.keptBackups)).", systemImage: "doc.on.doc")
            }
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text("Changed in " + tilde(setup.settingsFile.path) + ":").font(.callout.weight(.medium))
            ScrollView([.horizontal, .vertical]) {
                Text("Now:\n\(tables.now ?? "(none)")\n\nAfter:\n\(moved ? "the same, with this copy's path" : tables.after ?? "(none)")")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 170)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            Text("Command: \(tilde(setup.wrapperURL.path))").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if stop {
                    Button("Stop") { setup.turnOff(); dismiss() }
                }
                if moved {
                    Button("Turn Off") { setup.turnOff(); dismiss() }
                    Button("Fix") { setup.turnOn(); dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(on ? "Turn Off" : "Turn On") {
                        if on { setup.turnOff() } else { setup.turnOn() }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
