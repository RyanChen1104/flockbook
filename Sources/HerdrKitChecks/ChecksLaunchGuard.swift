import Foundation
@testable import HerdrKit

/// The launch guard: a check flag the app does not know, or a flag with its value in one argument, never reaches a normal
/// launch (real window, Dock icon). And every check flag the app's sources and scripts use is a known one.
func checksLaunchGuard() async throws {
    let app = "/x/HerdrDesk"
    func ok(_ args: [String]) -> Bool { LaunchGuard.problem([app] + args) == nil }
    check(ok([]), "launch guard: a plain launch")
    check(ok(["--session", "c9-input-test", "--read-only"]), "launch guard: ordinary options")
    check(ok(["--snapshot-settings", "/tmp/a b/dir"]), "launch guard: a value with a space, in its own argument")
    check(ok(["--test-sidebar"]) && ok(["--snapshot", "build/x"]) && ok(["--test-update", "http://127.0.0.1:8765/appcast.xml"]),
          "launch guard: known check flags")
    check(ok(["--test-screencolumn", "--light"]), "launch guard: a content check (ContentTests)")
    check(ok(["--test-fullscreen-real"]) && ok(["--test-scroll-real"]), "launch guard: the real-window checks are known")
    check(ok(["-NSDocumentRevisionsDebugMode", "YES"]) && ok(["-psn_0_12345"]), "launch guard: system arguments (one dash)")
    check(!ok(["--snapshot-settings /tmp/dir"]), "launch guard: flag and value in one argument (zsh, unquoted variable)")
    check(!ok(["--test-sidebar "]), "launch guard: trailing space")
    check(!ok(["--session c9-input-test"]), "launch guard: any -- argument with whitespace")
    check(!ok(["--test-sidebr"]) && !ok(["--snapshot-setings", "/tmp/x"]), "launch guard: misspelt check flags")
    check(!ok(["--test"]) && !ok(["--snapshot-"]), "launch guard: bare prefixes are not flags")
    check(!ok(["--test-sidebar", "--test-nope"]), "launch guard: one bad flag among good ones")
    let why = LaunchGuard.problem([app, "--snapshot-settings /tmp/dir"]) ?? ""
    check(why.contains("--snapshot-settings /tmp/dir") && why.lowercased().contains("usage"), "launch guard: the usage line names the argument (\(why))")
    check(LaunchGuard.problem([app, "--test-local-only"], known: ["--test-local-only"]) == nil, "launch guard: extra known flags from the caller")

    // Every check flag in the app's sources and scripts is known: a new flag fails here until it is listed.
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let regex = try NSRegularExpression(pattern: #"--(?:test|snapshot)[A-Za-z0-9-]*"#)
    var used = Set<String>(), files = 0
    for dir in ["Sources/HerdrDesk", "scripts"] {
        let url = root.appendingPathComponent(dir)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] where name.hasSuffix(".swift") || name.hasSuffix(".sh") {
            guard let text = try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8) else { continue }
            files += 1
            // Flags in Swift are string literals ("--test-x"); in scripts, words.
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let flag = String(text[Range(m.range, in: text)!])
                if name.hasSuffix(".swift") {
                    let r = Range(m.range, in: text)!
                    guard r.lowerBound > text.startIndex, text[text.index(before: r.lowerBound)] == "\"",
                          r.upperBound < text.endIndex, text[r.upperBound] == "\"" else { continue }
                }
                used.insert(flag)
            }
        }
    }
    let prefixes: Set<String> = ["--test", "--snapshot"]   // hasPrefix tests, not flags
    let unknown = used.subtracting(prefixes).subtracting(LaunchGuard.known).sorted()
    check(files > 40 && used.count > 40, "launch guard: scanned the app's sources and scripts (\(files) files, \(used.count) flags)")
    check(unknown.isEmpty, "launch guard: every check flag the app uses is known (unknown: \(unknown))")
}
