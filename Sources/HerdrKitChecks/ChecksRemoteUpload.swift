import Foundation
@testable import HerdrKit

// Remote herdr (Upload): pasted images go to the host before their path is typed, the tab's git branch is read on the
// host, and the local send plan is unchanged. `Via.local` runs the host side with /bin/sh on this Mac, in temp folders.
@MainActor func checksRemoteUpload() async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("fb-upload-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: tmp) }
    let local = tmp.appendingPathComponent("local", isDirectory: true)
    try fm.createDirectory(at: local, withIntermediateDirectories: true)
    let hostDir = tmp.appendingPathComponent("host/paste").path
    let host = RemoteHost(via: .local)
    func mode(_ p: String) -> Int? { (try? fm.attributesOfItem(atPath: p)[.posixPermissions] as? NSNumber)?.intValue }

    // The local plan is what it was before remote support: text, then each own image file as a paste.
    let uuid = UUID().uuidString
    let image = local.appendingPathComponent("\(uuid).png")
    var bytes = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
    bytes.replaceSubrange(0..<4, with: [0x89, 0x50, 0x4E, 0x47])
    try bytes.write(to: image)
    let message = "look at this \(image.path)"
    let plan = ImagePaste.plan(message, directory: local.path)
    check(plan == [.input("look at this "), .paste(image.path)], "remote upload: local plan unchanged (\(plan))")

    // Upload: identical bytes under the host folder, file 600, folder 700; the paste step names the host path.
    let up = RemoteUpload(host: host, folder: hostDir)
    let steps = try await up.hostSteps(plan)
    guard steps.count == 2, case .paste(let hostPath) = steps[1] else { check(false, "remote upload: two steps (\(steps))"); return }
    check(steps[0] == .input("look at this "), "remote upload: text step kept")
    check(hostPath.hasPrefix(hostDir + "/") && hostPath != image.path, "remote upload: host path under the host folder (\(hostPath))")
    check(fm.contents(atPath: hostPath) == bytes, "remote upload: same bytes on the host")
    check(mode(hostPath) == 0o600, "remote upload: file mode 600 (\(String(mode(hostPath) ?? 0, radix: 8)))")
    check(mode(hostDir) == 0o700, "remote upload: folder mode 700 (\(String(mode(hostDir) ?? 0, radix: 8)))")
    let typed = steps.map { (s: ImagePaste.Step) -> String in if case .paste(let p) = s { ImagePaste.paste(p) } else if case .input(let t) = s { t } else { "" } }.joined()
    check(typed.contains(hostPath) && !typed.contains(image.path), "remote upload: the text sent has the host path, not the local one")

    // Plain text: nothing runs on the host (the folder is not even made).
    let other = tmp.appendingPathComponent("host2/paste").path
    let plain = try await RemoteUpload(host: host, folder: other).hostSteps([.input("hello")])
    check(plain == [.input("hello")] && !fm.fileExists(atPath: other), "remote upload: no image, no host call")

    // Old uploads (over a day) go; new ones and names that are not ours stay.
    do {
        let old = hostDir + "/\(UUID().uuidString).png", foreign = hostDir + "/notes.png"
        for p in [old, foreign] {
            fm.createFile(atPath: p, contents: Data("x".utf8))
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: p)
        }
        _ = try await up.hostSteps(plan)
        check(!fm.fileExists(atPath: old), "remote upload: uploads older than a day are removed")
        check(fm.fileExists(atPath: foreign) && fm.fileExists(atPath: hostPath), "remote upload: other names and new uploads stay")
    }

    // A host folder that is a link is refused; failures read as a sentence with the host's label.
    do {
        let target = tmp.appendingPathComponent("elsewhere").path
        try fm.createDirectory(atPath: target, withIntermediateDirectories: true)
        let link = tmp.appendingPathComponent("linked").path
        try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        var why = ""
        do { _ = try await RemoteUpload(host: host, folder: link).hostSteps(plan) } catch { why = "\(error)" }
        check(why.contains(host.label) && ((try? fm.contentsOfDirectory(atPath: target)) ?? []).isEmpty,
              "remote upload: linked folder refused, nothing written (\(why))")
        var why2 = ""
        do { _ = try await RemoteUpload(host: host, folder: "/dev/null/paste").hostSteps(plan) } catch { why2 = "\(error)" }
        check(why2.hasPrefix("The image could not be copied to"), "remote upload: readable failure (\(why2))")
        // A host folder whose path holds a control character is not pasted (it could end the bracketed paste).
        var why3 = ""
        do { _ = try await RemoteUpload(host: host, folder: tmp.appendingPathComponent("a\u{1b}b").path).hostSteps(plan) } catch { why3 = "\(error)" }
        check(why3.contains("control characters"), "remote upload: control characters in the host folder refused (\(why3))")
    }

    // Attached or dropped files of any kind go to the same host folder; the composer types the host path. Folders are
    // refused with a hint. Names are made safe and unique; the extension stays.
    do {
        let doc = local.appendingPathComponent("my notes (v2).pdf")
        let docBytes = Data((0..<2000).map { UInt8($0 % 251) })
        try docBytes.write(to: doc)
        let p = try await up.uploadFile(doc)
        check(p.hasPrefix(hostDir + "/file-") && p.hasSuffix("-my_notes__v2_.pdf"), "remote upload: attached file under the host folder (\(p))")
        check(fm.contents(atPath: p) == docBytes && mode(p) == 0o600, "remote upload: attached file same bytes, mode 600")
        let p2 = try await up.uploadFile(doc)
        check(p2 != p && fm.contents(atPath: p) == docBytes, "remote upload: the same file twice gets two names")
        let n = RemoteUpload.uploadName(for: ".a b;$(x)'é\n.tar.gz")
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        check(n.hasPrefix("file-") && n.hasSuffix(".tar.gz") && n.unicodeScalars.allSatisfy(safe.contains) && !n.contains("-."),
              "remote upload: upload name is safe (\(n))")
        check(RemoteUpload.uploadName(for: String(repeating: "x", count: 500) + ".png").utf8.count <= 120, "remote upload: long names are cut")
        var why = ""
        do { _ = try await up.uploadFile(local) } catch { why = "\(error)" }
        check(why == RemoteUpload.folderNote(host: host), "remote upload: a folder is refused with a hint (\(why))")
        check(RemoteUpload.folderNote(host: host).contains(host.label), "remote upload: the folder hint names the host")
        var why2 = ""
        do { _ = try await up.uploadFile(local.appendingPathComponent("missing.txt")) } catch { why2 = "\(error)" }
        check(why2.hasPrefix("The file could not be copied to \(host.label)"), "remote upload: missing file reads as a sentence (\(why2))")
        // Old attached files are removed with old images.
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: p)
        _ = try await up.uploadFile(doc)
        check(!fm.fileExists(atPath: p) && fm.fileExists(atPath: p2), "remote upload: attached files older than a day are removed")
    }

    // Folder expressions: "~/" is the host's $HOME, anything else is quoted as is.
    check(RemoteUpload.pathWord("~/.cache/a b") == "\"$HOME\"/'.cache/a b'", "remote upload: ~/ is the host home")
    check(RemoteUpload.pathWord("/x/it's") == "'/x/it'\\''s'", "remote upload: absolute path quoted")
    check(RemoteUpload.defaultFolder == "~/.cache/flockbook/paste", "remote upload: default host folder")

    // Git branch on the host: the cwd is quoted (odd names work, nothing in it runs).
    do {
        let repo = tmp.appendingPathComponent("it's a $(touch pwned) repo").path
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let git = try await host.run(RemoteHost.commandLine(["/usr/bin/git", "-C", repo, "init", "-q", "-b", "trunk"]) + " && "
            + RemoteHost.commandLine(["/usr/bin/git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                                      "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                                      "commit", "-q", "--allow-empty", "-m", "x"]))
        check(git.ok, "remote upload: test repo made (\(git.stderr))")
        let cmd = RemoteGit.branchCommand(cwd: repo)
        check(cmd.contains(RemoteHost.quote(repo)), "remote upload: git cwd quoted (\(cmd))")
        let b = await RemoteGit.branch(cwd: repo, host: host)
        check(b == "trunk", "remote upload: branch read on the host (\(b ?? "nil"))")
        check(!fm.fileExists(atPath: tmp.appendingPathComponent("pwned").path) && !fm.fileExists(atPath: "pwned"),
              "remote upload: nothing in the cwd ran")
        check(await RemoteGit.branch(cwd: tmp.path + "/missing", host: host) == nil, "remote upload: no repo, no branch")
        check(RemoteGit.branchCommand(cwd: "~/src").contains("\"$HOME\"/'src'"), "remote upload: git ~/ cwd is the host home")
    }
}
