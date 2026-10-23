import Foundation

/// Images for an agent on a `RemoteHost`. The composer and the hub save images on this Mac (`ImagePaste` names), but the
/// agent reads paths on the host: each image is copied to a private host folder first (folder 700, files 600, names as
/// on this Mac) and the host path is pasted instead. Attached and dropped files go to the same folder (`uploadFile`).
/// Uploads older than a day are removed on the next upload.
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
    func prepare(what: String = "image") async throws -> String {
        // Only names the app gives (`ImagePaste.isOwnName`, `uploadName`) are removed.
        let names = ["????????-????-????-????-????????????.png", "remote-*.png", "remote-*.jpg", "file-*"]
            .map { "-name \(RemoteHost.quote($0))" }.joined(separator: " -o ")
        let cmd = "umask 077; d=\(Self.pathWord(folder)); "
            + "if [ -L \"$d\" ]; then echo 'the upload folder is a link' >&2; exit 1; fi; "
            + "mkdir -p \"$d\" && [ -d \"$d\" ] && [ ! -L \"$d\" ] && [ -O \"$d\" ] && chmod 700 \"$d\" "
            + "|| { echo 'cannot make a private upload folder' >&2; exit 1; }; "
            + "find \"$d\" -maxdepth 1 -type f \\( \(names) \\) -mmin +\(Self.maxAgeMinutes) -exec rm -f {} + 2>/dev/null; "
            + "printf '%s' \"$d\""
        let r: RemoteHost.Result
        do { r = try await host.run(cmd, timeout: timeout) } catch { throw fail("\(error)", what: what) }
        let d = String(decoding: r.stdout, as: UTF8.self)
        guard r.ok, d.hasPrefix("/") else {
            let why = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw fail(r.status == -1 ? "the host did not answer in time" : why.isEmpty ? "exit status \(r.status)" : why, what: what)
        }
        // The path is pasted (`ImagePaste.paste`): a control character could end the bracketed paste early.
        guard !d.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) }) else {
            throw fail("the upload folder's path has control characters", what: what)
        }
        return d
    }

    /// Largest attached file copied to a host.
    public static let maxFileBytes = 100 << 20

    /// An attached or dropped file (any kind) copied to the host folder; returns its host path. A folder is refused
    /// with `folderNote`. The name is `uploadName`: unique, safe to type, extension kept.
    public func uploadFile(_ local: URL) async throws -> String {
        let fm = FileManager.default, own = local.lastPathComponent
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: local.path, isDirectory: &isDir) else { throw fail("\(own) is not on this Mac", what: "file") }
        if isDir.boolValue { throw Failure(description: Self.folderNote(host: host)) }
        let size = (try? fm.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maxFileBytes else { throw fail("\(own) is over \(Self.maxFileBytes >> 20) MB", what: "file") }
        guard let data = fm.contents(atPath: local.path) else { throw fail("\(own) on this Mac could not be read", what: "file") }
        let dir = try await prepare(what: "file")
        let path = dir + "/" + Self.uploadName(for: own)
        // about 2 s a megabyte on a slow link, on top of the usual time
        var files = RemoteFiles(host: host, timeout: timeout)
        files.timeout = timeout + .seconds(size / 500_000)
        do { try await files.write(data, to: path, mode: "600") } catch {
            if case HerdrError.socket(let m) = error { throw fail(m, what: "file") }
            throw fail("\(error)", what: "file")
        }
        return path
    }

    /// The host name of an attached file: `file-<8 hex>-<name>`, with every character but letters, digits, ".", "-"
    /// and "_" made "_", no leading dot, and at most the last 80 characters of the name (the extension stays).
    public static func uploadName(for name: String) -> String {
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var s = String(String.UnicodeScalarView(name.unicodeScalars.map { ok.contains($0) ? $0 : "_" }))
        s = String(s.suffix(80))
        while s.hasPrefix(".") { s.removeFirst() }
        return "file-" + UUID().uuidString.prefix(8).lowercased() + "-" + (s.isEmpty ? "file" : s)
    }

    /// What the composer says when a folder is attached or dropped for an agent on a host.
    public static func folderNote(host: RemoteHost) -> String {
        "Folders can't be copied to \(host.label). Attach the files in it instead."
    }

    private func fail(_ detail: String, what: String = "image") -> Failure {
        Failure(description: "The \(what) could not be copied to \(host.label): \(detail).")
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
