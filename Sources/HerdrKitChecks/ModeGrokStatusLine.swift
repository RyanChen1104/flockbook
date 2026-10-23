import Foundation
@testable import HerdrKit

// `HerdrKitChecks --grok-statusline <on|off> <config.toml> <wrapper> <dir>`: Settings' Grok Build status line switch
// (`GrokStatusLineSetting.apply`, the code the app calls) on a config file named here, for a live test with a backup
// of it. Prints the backup it made (none: nothing written) and the state after.
@MainActor func modeGrokStatusLine() async throws {
    guard let i = CommandLine.arguments.firstIndex(of: "--grok-statusline") else { return }
    let a = CommandLine.arguments
    guard a.count > i + 4, a[i + 1] == "on" || a[i + 1] == "off" else {
        print("usage: --grok-statusline <on|off> <config.toml> <wrapper> <dir>"); exit(2)
    }
    let file = URL(fileURLWithPath: a[i + 2]), folder = StatusLineFolder(url: URL(fileURLWithPath: a[i + 4], isDirectory: true))
    let command = ClaudeStatusLineSetting.command(wrapper: a[i + 3], dir: a[i + 4])
    do {
        let backup = try GrokStatusLineSetting.apply(on: a[i + 1] == "on", file: file, command: command, folder: folder)
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        print("grok-statusline: \(a[i + 1]) backup=\(backup?.path ?? "none") state=\(GrokStatusLineSetting.state(text, command: command, wasOn: folder.wasOn))")
        exit(0)
    } catch {
        print("grok-statusline: \(a[i + 1]) refused: \(error)"); exit(1)
    }
}
