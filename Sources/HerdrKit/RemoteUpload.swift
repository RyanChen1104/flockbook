import Foundation

/// Images for an agent on a `RemoteHost`. The composer and the hub save images on this Mac (`ImagePaste` names), but the
/// agent reads paths on the host: each image is copied to a private host folder first (folder 700, files 600, names as
/// on this Mac) and the host path is pasted instead. Uploads older than a day are removed on the next upload.
public struct RemoteUpload: Sendable {
    public let host: RemoteHost
    /// The host folder. "~/" is the host user's home; any other path is used as is.
    public let folder: String
    public var timeout: Duration

    public static let defaultFolder = "~/.cache/flockbook/paste"
    /// Uploads older than this (minutes) are removed.
    public static let maxAgeMinutes = 24 * 60

    public init(host: RemoteHost, folder: String = RemoteUpload.defaultFolder, timeout: Duration = .seconds(60)) {
        self.host = host; self.folder = folder; self.timeout = timeout
    }

    /// Why an upload failed, as a sentence for the composer's note.
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    /// One shell word for a host path: "~/x" becomes "$HOME"/'x', anything else is quoted.
    static func pathWord(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") { return "\"$HOME\"/" + RemoteHost.quote(String(path.dropFirst(2))) }
        return RemoteHost.quote(path)
    }

    /// `steps` (`ImagePaste.plan` on this Mac) with every pasted image copied to the host and its host path in place of
    /// the local one. Text steps stay as they are. No image: no host call at all.
    public func hostSteps(_ steps: [ImagePaste.Step]) async throws -> [ImagePaste.Step] {
        guard steps.contains(where: { if case .paste = $0 { true } else { false } }) else { return steps }
        let dir = try await prepare()
        let files = RemoteFiles(host: host, timeout: timeout)
        var out = steps
        for (i, step) in steps.enumerated() {
            guard case .paste(let local) = step else { continue }
            let own = (local as NSString).lastPathComponent
            let name = ImagePaste.isOwnName(own) ? own : UUID().uuidString + ".png"
            guard let data = FileManager.default.contents(atPath: local) else { throw fail("the file \(own) on this Mac could not be read") }
            let path = dir + "/" + name
            do { try await files.write(data, to: path, mode: "600") } catch {
                if case HerdrError.socket(let m) = error { throw fail(m) }
                throw fail("\(error)")
            }
            out[i] = .paste(path)
        }
        return out
    }

    /// Makes the host folder (mode 700, ours, not a link), removes uploads over a day old and returns the folder's
    /// absolute path on the host.
    func prepare() async throws -> String {
        // Only names the app gives (`ImagePaste.isOwnName`) are removed.
        let names = ["????????-????-????-????-????????????.png", "remote-*.png", "remote-*.jpg"]
            .map { "-name \(RemoteHost.quote($0))" }.joined(separator: " -o ")
        let cmd = "umask 077; d=\(Self.pathWord(folder)); "
            + "if [ -L \"$d\" ]; then echo 'the upload folder is a link' >&2; exit 1; fi; "
            + "mkdir -p \"$d\" && [ -d \"$d\" ] && [ ! -L \"$d\" ] && [ -O \"$d\" ] && chmod 700 \"$d\" "
            + "|| { echo 'cannot make a private upload folder' >&2; exit 1; }; "
            + "find \"$d\" -maxdepth 1 -type f \\( \(names) \\) -mmin +\(Self.maxAgeMinutes) -exec rm -f {} + 2>/dev/null; "
            + "printf '%s' \"$d\""
        let r: RemoteHost.Result
        do { r = try await host.run(cmd, timeout: timeout) } catch { throw fail("\(error)") }
        let d = String(decoding: r.stdout, as: UTF8.self)
        guard r.ok, d.hasPrefix("/") else {
            let why = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw fail(r.status == -1 ? "the host did not answer in time" : why.isEmpty ? "exit status \(r.status)" : why)
        }
        // The path is pasted (`ImagePaste.paste`): a control character could end the bracketed paste early.
        guard !d.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) }) else {
            throw fail("the upload folder's path has control characters")
        }
        return d
    }

    private func fail(_ detail: String) -> Failure {
        Failure(description: "The image could not be copied to \(host.label): \(detail).")
    }
}

/// The git branch of a folder on a `RemoteHost` (the tab header). Read-only; nil on any failure.
public enum RemoteGit {
    /// The command line: `git -C <cwd> rev-parse --abbrev-ref HEAD`, the cwd quoted ("~/" is the host home).
    public static func branchCommand(cwd: String) -> String {
        "git -C \(RemoteUpload.pathWord(cwd)) rev-parse --abbrev-ref HEAD 2>/dev/null"
    }

    public static func branch(cwd: String, host: RemoteHost, timeout: Duration = .seconds(5)) async -> String? {
        guard let r = try? await host.run(branchCommand(cwd: cwd), timeout: timeout), r.ok else { return nil }
        let s = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty || s.contains("\n") ? nil : s
    }
}
