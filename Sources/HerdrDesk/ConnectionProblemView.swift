import AppKit
import HerdrKit
import SwiftUI

/// The content area while the app cannot reach herdr and has nothing to show: what is wrong and the next step
/// (a command to copy, the install page), with Try Again. The store keeps retrying on its own.
struct ConnectionProblemView: View {
    let problem: ConnectionProblem
    let retry: () async -> Void
    @State private var copied = false
    @State private var trying = false

    var body: some View {
        ContentUnavailableView {
            Label(problem.title, systemImage: problem == .herdrMissing ? "shippingbox" : "bolt.horizontal.circle")
        } description: {
            Text(problem.detail)
        } actions: {
            VStack(spacing: 12) {
                if let command = problem.command {
                    // The whole command, wrapped if long: a cut command cannot be typed.
                    Text(command).font(.body.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.control))
                }
                HStack(spacing: 8) {
                    if let command = problem.command {
                        Button(copied ? "Copied" : "Copy Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            copied = true
                        }
                    }
                    if let link = problem.link { Link("Get herdr", destination: link).buttonStyle(.borderedProminent) }
                    Button(trying ? "Trying…" : "Try Again") {
                        trying = true
                        Task { await retry(); trying = false }
                    }
                    .disabled(trying)
                }
                .fixedSize()
            }
        }
        // The whole detail column, as the other screens: alone, the view only takes its text's width.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
