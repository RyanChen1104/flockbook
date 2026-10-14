// flockbook-notify: an agent's own phone notification through the running Flockbook app.
//   flockbook-notify "Title" ["Body"] [--pane <id>]
// The tap opens --pane, else $HERDR_PANE_ID (the pane the agent runs in). The body is cut to 200 characters. Talks to
// the app on 127.0.0.1 with the token in ~/Library/Application Support/Flockbook/hub/notify.json (mode 600).
// Exit: 0 sent (or no phone subscribed), 1 usage, 2 the app is not running or Remote access is off, 3 refused.
import Foundation
import HerdrKit

let usage = """
    usage: flockbook-notify "Title" ["Body"] [--pane <id>]
    Sends a notification to the phones that turned on notifications in Flockbook.
    """
var args = Array(CommandLine.arguments.dropFirst())
var pane = ProcessInfo.processInfo.environment["HERDR_PANE_ID"]
if let i = args.firstIndex(of: "--pane") {
    guard args.indices.contains(i + 1) else { FileHandle.standardError.write(Data((usage + "\n").utf8)); exit(1) }
    pane = args[i + 1]
    args.removeSubrange(i...i + 1)
}
if args.contains(where: { $0 == "-h" || $0 == "--help" }) { print(usage); exit(0) }
guard (1...2).contains(args.count), !args[0].trimmingCharacters(in: .whitespaces).isEmpty else {
    FileHandle.standardError.write(Data((usage + "\n").utf8)); exit(1)
}
let file = ProcessInfo.processInfo.environment["FLOCKBOOK_NOTIFY_FILE"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Flockbook/hub/notify.json")
do {
    let n = try await NotifyClient.send(title: args[0], body: args.count > 1 ? args[1] : "", pane: pane, file: file)
    print(n == 0 ? "flockbook-notify: no phone got it (none subscribed, or held by the rate limit)." : "flockbook-notify: sent to \(n) \(n == 1 ? "phone" : "phones").")
    exit(0)
} catch NotifyClient.Failure.notRunning {
    FileHandle.standardError.write(Data("flockbook-notify: Flockbook is not running, or Remote access is off.\n".utf8)); exit(2)
} catch NotifyClient.Failure.refused(let status, let why) {
    FileHandle.standardError.write(Data("flockbook-notify: refused (\(status)): \(why)\n".utf8)); exit(3)
}
