import HerdrKit
import SwiftUI

/// Settings > Agents: "Show Claude Code status line". Off until the owner switches it on; the sheet shows the exact
/// change to Claude Code's settings file before anything is written. If the owner sets another status line later
/// (`/statusline`), the row says so and asks them to switch it on again.
struct StatusLineRow: View {
    let setup: StatusLineSetup
    @State private var sheet = false

    var body: some View {
        SettingsGroup("Status line", note: note, noteColor: isProblem ? .red : setup.state == .replaced || setup.state == .moved ? .orange : nil) {
            SettingsRow("Show Claude Code status line", value: value, valueColor: isProblem ? .red : nil) {
                if setup.state == .moved {
                    Button("Fix…") { sheet = true }
                }
                Toggle("Show Claude Code status line", isOn: Binding(get: { setup.state == .on || setup.state == .moved }, set: { _ in sheet = true }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            .settingsControl(.statusLine)
        }
        .sheet(isPresented: $sheet) { StatusLineSheet(setup: setup) }
        .disabled(setup.busy)
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
        switch setup.state {
        case .off: "Off for Claude Code on \(setup.machine). Shows the line Claude Code draws under its prompt under each Claude composer, and on the phone."
        case .on: "On for Claude Code on \(setup.machine). Claude Code runs your own status line through Flockbook, and shows it as before."
        case .replaced: "Claude Code's status line was changed since (for example with /statusline). Switch this on again to show the new one."
        case .moved: "Needs fixing: Flockbook moved since this was switched on, and Claude Code still runs the old copy's command."
        case .problem(let m): "Could not read Claude Code's settings on \(setup.machine): \(m)."
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
            Text("Changed in " + setup.settingsLabel + ":").font(.callout.weight(.medium))
            ScrollView([.horizontal, .vertical]) {
                Text(preview(on: on)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: moved ? 150 : 190)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            Text("Command: \(setup.wrapperLabel)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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

    /// The statusLine before → after, with "~" for the home folder.
    private func preview(on: Bool) -> String {
        let ours: [String: Any] = ["type": "command", "command": setup.command]
        let theirs: [String: Any]? = setup.originalSummary.map { ["type": "command", "command": $0] }
        func json(_ v: Any?) -> String {
            guard let v else { return "(none)" }
            let d = (try? JSONSerialization.data(withJSONObject: ["statusLine": v], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: d, as: UTF8.self).replacingOccurrences(of: setup.home, with: "~")
        }
        if setup.state == .moved {
            return "Now:\n\(json(setup.currentCommand.map { ["type": "command", "command": $0] }))\n\nAfter:\n\(json(ours))"
        }
        return on ? "Now:\n\(json(ours))\n\nAfter:\n\(json(theirs))" : "Now:\n\(json(theirs))\n\nAfter:\n\(json(ours))"
    }
}
