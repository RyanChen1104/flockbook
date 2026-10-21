import HerdrKit
import SwiftUI

/// Settings > Agents: "Show Claude Code status line". Off until the owner switches it on; the sheet shows the exact
/// change to Claude Code's settings file before anything is written. If the owner sets another status line later
/// (`/statusline`), the row says so and asks them to switch it on again.
struct StatusLineRow: View {
    let setup: StatusLineSetup
    @State private var sheet = false

    var body: some View {
        Toggle(isOn: Binding(get: { setup.state == .on }, set: { _ in sheet = true })) {
            Text("Show Claude Code status line")
            Text(note).foregroundStyle(isProblem ? AnyShapeStyle(.red) : setup.state == .replaced ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .sheet(isPresented: $sheet) { StatusLineSheet(setup: setup) }
        .onAppear { setup.refresh() }
    }

    private var isProblem: Bool { if case .problem = setup.state { true } else { false } }

    private var note: String {
        switch setup.state {
        case .off: "Off. Shows the line Claude Code draws under its prompt under each Claude composer, and on the phone."
        case .on: "On. Claude Code runs your own status line through Flockbook, and shows it as before."
        case .replaced: "Claude Code's status line was changed since (for example with /statusline). Switch this on again to show the new one."
        case .problem(let m): "Could not read Claude Code's settings: \(m)."
        }
    }
}

/// What switching on or off changes, shown before the owner clicks.
struct StatusLineSheet: View {
    let setup: StatusLineSetup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let on = setup.state == .on
        let tilde = ClaudeHookSheet.tilde
        VStack(alignment: .leading, spacing: 12) {
            Text(on ? "Stop Showing the Status Line" : "Show Claude Code's Status Line").font(.title3.weight(.semibold))
            Text(on ? "Turning this off puts your own status line back in the file below, as it was. Everything else stays."
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
                Label("A copy of the file is kept next to it before any change.", systemImage: "doc.on.doc")
            }
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text("Changed in " + tilde(setup.settingsFile.path) + ":").font(.callout.weight(.medium))
            ScrollView([.horizontal, .vertical]) {
                Text(preview(on: on)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 190)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            Text("Command: \(tilde(setup.wrapperURL.path))").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(on ? "Turn Off" : "Turn On") {
                    if on { setup.turnOff() } else { setup.turnOn() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
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
            return String(decoding: d, as: UTF8.self).replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        }
        return on ? "Now:\n\(json(ours))\n\nAfter:\n\(json(theirs))" : "Now:\n\(json(theirs))\n\nAfter:\n\(json(ours))"
    }
}
