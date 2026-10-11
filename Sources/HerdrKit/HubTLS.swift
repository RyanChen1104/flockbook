import Foundation
import CryptoKit
import Security
import Network

/// The hub's TLS identity: certificate and key, imported in memory only (never into a keychain).
public struct HubIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    public let certificateDER: Data
    /// SHA-256 of the certificate, lowercase hex. The QR code carries it; clients pin it.
    public let fingerprint: String
}

/// Certificates for the hub. A self-signed one is made with the system `/usr/bin/openssl` (no dependency); a
/// `tailscale cert` pair is taken as PEM files. Files are mode 600 in a mode 700 folder.
public enum HubTLS {
    public enum Failure: Error, Equatable {
        case openssl(String)
        case importFailed(Int32)
        /// An EC certificate with explicit curve parameters (not importable).
        case explicitCurve
    }

    static let p12Name = "identity.p12"
    /// The p12 sits next to the key in the same 600 files; its password adds nothing and is fixed.
    static let p12Password = "flockbook-hub"

    public static func fingerprint(der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Makes a new self-signed certificate (P-256, about 2 years) for `names` (IP addresses or DNS names) in `dir`.
    public static func selfSigned(in dir: URL, names: [String]) throws -> HubIdentity {
        try prepare(dir)
        let key = dir.appendingPathComponent("key.pem"), cert = dir.appendingPathComponent("cert.pem")
        let san = names.map { IPv4Address($0) != nil || IPv6Address($0) != nil ? "IP:\($0)" : "DNS:\($0)" }.joined(separator: ",")
        try openssl(["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                     "-pkeyopt", "ec_param_enc:named_curve", "-nodes",
                     "-keyout", key.path, "-out", cert.path, "-days", "825", "-subj", "/CN=Flockbook hub"]
                    + (san.isEmpty ? [] : ["-addext", "subjectAltName=\(san)"]))
        try lock([key, cert])
        return try fromPEM(cert: cert, key: key, into: dir)
    }

    /// Bundles a PEM certificate and key (for example from `tailscale cert`) into `dir` and loads it.
    public static func fromPEM(cert: URL, key: URL, into dir: URL) throws -> HubIdentity {
        try prepare(dir)
        let p12 = dir.appendingPathComponent(p12Name)
        // The in-memory import raises an Objective-C exception (a crash, Swift cannot catch it) on EC keys with
        // explicit curve parameters. Refuse those before the import. (`tailscale cert` and our own use named curves.)
        let text = try openssl(["x509", "-in", cert.path, "-noout", "-text"])
        if text.contains("Field Type:") { throw Failure.explicitCurve }
        try openssl(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", p12.path, "-passout", "pass:\(p12Password)",
                     "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1"])
        try lock([p12])
        return try importP12(Data(contentsOf: p12))
    }

    /// The identity stored in `dir`, or nil when there is none.
    public static func load(from dir: URL) throws -> HubIdentity? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(p12Name)) else { return nil }
        return try importP12(data)
    }

    static func importP12(_ data: Data) throws -> HubIdentity {
        var items: CFArray?
        let opts: [String: Any] = [kSecImportExportPassphrase as String: p12Password, kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(data as CFData, opts as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let any = first[kSecImportItemIdentity as String] else { throw Failure.importFailed(status) }
        let identity = any as! SecIdentity
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else { throw Failure.importFailed(-1) }
        let der = SecCertificateCopyData(cert) as Data
        return HubIdentity(identity: identity, certificateDER: der, fingerprint: fingerprint(der: der))
    }

    private static func prepare(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private static func lock(_ files: [URL]) throws {
        for f in files { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path) }
    }

    /// Runs the system openssl; returns its standard output.
    @discardableResult
    private static func openssl(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        let out = Pipe()
        p.standardOutput = out
        do { try p.run() } catch { throw Failure.openssl("\(error)") }
        // Standard output first: openssl writes only a few lines to standard error, so that pipe never fills.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let msg = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure.openssl(String(decoding: msg, as: UTF8.self).suffix(300).description) }
        return String(decoding: outData, as: UTF8.self)
    }
}

/// An address of this Mac the hub may listen on.
public struct HubAddress: Hashable, Sendable {
    public var host: String
    /// nil: a public address (refused).
    public var kind: HubBind.Kind?
    public var interface: String
    public init(host: String, kind: HubBind.Kind?, interface: String) { self.host = host; self.kind = kind; self.interface = interface }
}

/// Where the hub may listen: one address of this Mac that the owner picks. Never all addresses (0.0.0.0 / ::), never
/// a public address, and TLS on everything but loopback.
public enum HubBind {
    public enum Kind: String, Hashable, Sendable { case loopback, tailscale, lan }

    public static func kind(_ host: String) -> Kind? {
        if let v4 = IPv4Address(host) {
            let b = [UInt8](v4.rawValue)
            switch (b[0], b[1]) {
            case (127, _): return .loopback
            case (0, _): return nil
            case (100, 64...127): return .tailscale   // CGNAT range Tailscale uses
            case (10, _), (192, 168), (172, 16...31): return .lan
            default: return nil
            }
        }
        if let v6 = IPv6Address(host) {
            let b = [UInt8](v6.rawValue)
            if v6 == .loopback { return .loopback }
            if b.starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]) { return .tailscale }
            if b[0] & 0xfe == 0xfc { return .lan }   // unique local fc00::/7
            return nil   // link-local, global, unspecified
        }
        return nil
    }

    public static func isWildcard(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces)
        return h.isEmpty || h == "*" || h == "0.0.0.0" || h == "::" || h == "[::]"
    }

    /// Nil when `host` may be used; else why not. `local`: this Mac's addresses (`local()`).
    public static func check(host: String, tls: Bool, local: [HubAddress]) -> HubServer.StartError? {
        if isWildcard(host) { return .wildcard(host) }
        guard let a = local.first(where: { $0.host == host }) else { return .notLocal(host) }
        guard let k = a.kind ?? kind(host) else { return .publicAddress(host) }
        if k != .loopback && !tls { return .needsTLS(host) }
        return nil
    }

    /// This Mac's usable addresses now: loopback, Tailscale and private LAN ones (no link-local, no public).
    public static func local() -> [HubAddress] {
        var out: [HubAddress] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, ifa.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let fam = Int32(sa.pointee.sa_family)
            guard fam == AF_INET || fam == AF_INET6 else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(fam == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = String(cString: buf)
            guard !host.contains("%"), let k = kind(host) else { continue }
            let a = HubAddress(host: host, kind: k, interface: String(cString: ifa.ifa_name))
            if !out.contains(a) { out.append(a) }
        }
        return out
    }
}
