import Foundation

/// Files on a `RemoteHost`, one short command each (ssh shares one connection per host, so a command costs a round trip,
/// not a login). Paths are the host's; every path is quoted. Bytes come back raw on stdout (ssh -T is binary-safe).
/// Nil or false: missing, unreadable, or the host did not answer.
public struct RemoteFiles: Sendable {
    public let host: RemoteHost
    public var timeout: Duration

    public init(host: RemoteHost, timeout: Duration = .seconds(30)) { self.host = host; self.timeout = timeout }

    private func q(_ s: String) -> String { RemoteHost.quote(s) }

    /// The host user's home folder.
    public func home() async -> String? {
        guard let r = try? await host.run("printf '%s' \"$HOME\"", timeout: timeout), r.ok else { return nil }
        let h = String(decoding: r.stdout, as: UTF8.self)
        return h.hasPrefix("/") ? h : nil
    }

    /// Size in bytes of a regular file.
    public func size(_ path: String) async -> UInt64? {
        guard let r = try? await host.run("[ -f \(q(path)) ] && wc -c < \(q(path))", timeout: timeout), r.ok else { return nil }
        return UInt64(String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Up to `count` bytes from byte `offset`. Fewer at the end of the file; nil when the file cannot be read.
    public func read(_ path: String, offset: UInt64, count: Int) async -> Data? {
        guard count > 0 else { return Data() }
        let cmd = "[ -r \(q(path)) ] && tail -c +\(offset + 1) \(q(path)) | head -c \(count)"
        guard let r = try? await host.run(cmd, timeout: timeout), r.ok else { return nil }
        return r.stdout
    }

    public func isFile(_ path: String) async -> Bool {
        (try? await host.run("[ -f \(q(path)) ]", timeout: timeout))?.ok ?? false
    }

    /// Names in a folder (no "." or ".."), unsorted. Nil: not a readable folder.
    public func list(_ dir: String) async -> [String]? {
        guard let r = try? await host.run("[ -d \(q(dir)) ] && ls -1A \(q(dir))", timeout: timeout), r.ok else { return nil }
        return String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// The first regular file under `dir` (any depth) whose name ends with `suffix`. `suffix` is matched literally.
    public func find(under dir: String, nameSuffix suffix: String) async -> String? {
        // by Unicode scalar: a Character search misses a "*" with a combining mark after it
        var glob = String.UnicodeScalarView("*".unicodeScalars)
        for u in suffix.unicodeScalars {
            if "\\*?[".unicodeScalars.contains(u) { glob.append("\\") }
            glob.append(u)
        }
        let cmd = "[ -d \(q(dir)) ] && find \(q(dir)) -type f -name \(q(String(glob))) 2>/dev/null | head -n 1"
        guard let r = try? await host.run(cmd, timeout: timeout), r.ok else { return nil }
        let p = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        return p.isEmpty ? nil : p
    }

    /// Writes `data` to `path` through a temp file in the same folder, then renames it (readers never see half a file).
    /// Makes the folder (mode 700) when missing. `mode`: the file's permissions, e.g. "600" or "700".
    public func write(_ data: Data, to path: String, mode: String = "600") async throws {
        guard mode.allSatisfy({ ("0"..."7").contains($0) }), (3...4).contains(mode.count) else {
            throw HerdrError.protocolError("bad file mode \(mode)")
        }
        let dir = (path as NSString).deletingLastPathComponent
        let cmd = "umask 077 && mkdir -p \(q(dir)) && t=$(mktemp \(q(path + ".XXXXXX"))) && cat > \"$t\" && chmod \(mode) \"$t\" && mv -f \"$t\" \(q(path)) || { rm -f \"$t\" 2>/dev/null; exit 1; }"
        let r = try await host.run(cmd, input: data, timeout: timeout)
        guard r.ok else { throw HerdrError.socket("writing \(path) on \(host.label) failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    /// Removes a file; true when it is gone afterwards.
    @discardableResult
    public func remove(_ path: String) async -> Bool {
        (try? await host.run("rm -f \(q(path))", timeout: timeout))?.ok ?? false
    }
}
