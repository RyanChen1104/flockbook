import HerdrKit
import SwiftUI

/// Settings > Remote access: "Answer Claude questions from the phone". Off until the owner installs the hook; the
/// sheet shows the exact change to Claude Code's settings file before anything is written.
struct ClaudeHookRow: View {
    let setup: ClaudeHookSetup
    @State private var sheet = false

    var body: some View {
        LabeledContent {
            Button(setup.state == .on ? "Uninstall…" : "Install…") { sheet = true }
        } label: {
            Text("Answer Claude questions from the phone")
            Text(note).foregroundStyle(isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        .sheet(isPresented: $sheet) { ClaudeHookSheet(setup: setup) }
        .onAppear { setup.refresh() }
    }

    private var isProblem: Bool { if case .problem = setup.state { true } else { false } }

    private var note: String {
        switch setup.state {
        case .off: "Off. Claude Code questions are answered on the Mac. Codex questions work from the phone already."
        case .on: "On. Claude sessions started from now on save each question for Flockbook."
        case .problem(let m): "Could not read Claude Code's settings: \(m)."
        }
    }
}

/// What Install or Uninstall changes, shown before the owner clicks.
struct ClaudeHookSheet: View {
    let setup: ClaudeHookSetup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let on = setup.state == .on
        VStack(alignment: .leading, spacing: 12) {
            Text(on ? "Remove the Claude Code Hook" : "Answer Claude Questions from the Phone").font(.title3.weight(.semibold))
            Text(on ? "Uninstall removes only Flockbook's entry from the file below. Everything else stays."
                    : "Claude Code shows a question picker only on screen. A small hook lets Claude Code tell Flockbook the exact question first, so the phone can answer it.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Label("The hook only saves the question to Flockbook's own folder. It never blocks or changes Claude Code.", systemImage: "checkmark.shield")
                Label("The phone answers only when the picker on screen matches that question exactly. Else it says to answer on the Mac.", systemImage: "eye")
                Label("A copy of the file is kept next to it before any change.", systemImage: "doc.on.doc")
                Label("Claude sessions started after this use it. Restart a running session to include it.", systemImage: "arrow.clockwise")
            }
            .font(.callout).foregroundStyle(.secondary)
            Text(on ? "Removed from \(Self.tilde(setup.settingsFile.path)):" : "Added to \(Self.tilde(setup.settingsFile.path)):").font(.callout.weight(.medium))
            ScrollView([.horizontal, .vertical]) {
                Text(setup.preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 170)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            Text("Script: \(Self.tilde(setup.scriptURL.path))").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(on ? "Uninstall" : "Install") {
                    if on { setup.uninstall() } else { setup.install() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    static func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}
