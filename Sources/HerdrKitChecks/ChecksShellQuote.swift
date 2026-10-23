import Foundation
@testable import HerdrKit

/// Shell quoting (ShellQuote and every place that quotes for /bin/sh): /bin/sh reads each quoted value back exactly,
/// and runs nothing in it, also when a ' carries a combining mark (one Character to Swift, two scalars to the shell).
func checksShellQuote() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shellquote-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let mark = dir.appendingPathComponent("MARK")
    let inputs = [
        "x'\u{301}$(echo INJECTED)", "x'\u{301}; touch MARK", "'\u{301}`touch MARK`'\u{20DD}", "x'\u{20DD}$(touch MARK)",
        "it's", "plain/path.txt", "", "é'\u{301}", "$(touch MARK)", "`touch MARK`", "a b (c) & d;\"e\"",
    ]
    /// What /bin/sh prints for `printf %s <quoted>`, run in `dir`.
    func shRead(_ quoted: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf %s " + quoted]
        p.currentDirectoryURL = dir
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }
    let quoters: [(String, (String) -> String)] = [
        ("ShellQuote.quoted", ShellQuote.quoted),
        ("ShellQuote.quotedIfNeeded", ShellQuote.quotedIfNeeded),
        ("ClaudeQuestionHook.shellQuoted", ClaudeQuestionHook.shellQuoted),
        ("ConnectionCheck.shellQuoted", ConnectionCheck.shellQuoted),
        ("TailscaleSetup.command", { TailscaleSetup.command(cli: $0, []) }),
    ]
    for (name, quote) in quoters {
        var wrong: [String] = []
        for s in inputs {
            try? FileManager.default.removeItem(at: mark)
            let got = shRead(quote(s))
            if got != Data(s.utf8) || FileManager.default.fileExists(atPath: mark.path) {
                wrong.append("\(s.unicodeScalars.map { $0.isASCII ? String($0) : String(format: "U+%04X", $0.value) }.joined()) -> \(got.map { String(decoding: $0, as: UTF8.self) } ?? "nil")")
            }
        }
        check(wrong.isEmpty, "shell quote: \(name): /bin/sh reads every value back and runs nothing (wrong: \(wrong))")
    }
    // The composer's paths: quoted only when not plain; $ and ` are not plain.
    check(["/tmp/a.png", "/a/b-c_d.e"].allSatisfy { ShellQuote.quotedIfNeeded($0) == $0 }, "shell quote: a plain path stays as it is")
    check(["/a/$HOME", "/a/`x`", "/a/b c", "/a/é", "/a/x'\u{301}"].allSatisfy { ShellQuote.quotedIfNeeded($0).hasPrefix("'") },
          "shell quote: $, `, a space, a non-ASCII letter or a quote: quoted")
    // A pasted image path in a folder whose name has a ' with a combining mark is still found (quoted as the shell needs).
    let folder = "/tmp/x'\u{301}dir", file = "\(folder)/\(UUID().uuidString).png"
    let spelled = "'" + String(String.UnicodeScalarView(file.unicodeScalars.flatMap { $0 == "'" ? Array("'\\''".unicodeScalars) : [$0] })) + "'"
    check(ImagePaste.segments("see \(spelled)", directory: folder) == [.text("see "), .image(file)],
          "shell quote: an image path quoted per scalar is found in a folder with a ' and a combining mark")
}
