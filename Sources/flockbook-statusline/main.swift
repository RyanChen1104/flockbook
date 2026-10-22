// flockbook-statusline: Claude Code's statusLine command while "Show Claude Code status line" is on (Settings > Agents).
//   flockbook-statusline --dir <folder>
// Claude Code runs it with the session's JSON on stdin. It runs the owner's own statusLine command (kept in <folder>
// when the switch went on) with the same input and environment, prints its output unchanged and exits with its status,
// so Claude Code shows what it showed before. It also saves the input and the output in <folder> for Flockbook.
// No own command: prints nothing. A command still running after 10 s is stopped (its output so far is printed).
import Foundation
import HerdrKit

let usage = """
    usage: flockbook-statusline --dir <folder>
    Claude Code's statusLine command for Flockbook: runs your own statusLine command and shows its output unchanged.
    """
let args = Array(CommandLine.arguments.dropFirst())
if args.contains(where: { $0 == "-h" || $0 == "--help" }) { print(usage); exit(0) }
guard let i = args.firstIndex(of: "--dir"), args.indices.contains(i + 1), !args[i + 1].isEmpty else {
    FileHandle.standardError.write(Data((usage + "\n").utf8)); exit(0)
}
StatusLineWrapper.installSignalHandlers()
let input = FileHandle.standardInput.readDataToEndOfFile()
let r = StatusLineWrapper.run(input: input, dir: URL(fileURLWithPath: args[i + 1], isDirectory: true))
_ = StatusLineWrapper.emit(r.output)
exit(r.status)
