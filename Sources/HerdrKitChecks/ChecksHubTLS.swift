import Foundation
import CryptoKit
@testable import HerdrKit

/// Accepts the hub's certificate only when its SHA-256 is the pinned one (as a paired client does).
final class PinDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let pin: String
    var seen: String?
    init(pin: String) { self.pin = pin }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            completionHandler(.performDefaultHandling, nil); return
        }
        seen = HubTLS.fingerprint(der: SecCertificateCopyData(leaf) as Data)
        if seen == pin { completionHandler(.useCredential, URLCredential(trust: trust)) } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}

// Bind rules and TLS. Binds only on 127.0.0.1 here (a LAN or Tailscale bind would ask the firewall); the rules for
// other addresses are checked with a given interface list.
@MainActor func checksHubTLS() async throws {
    // Address kinds.
    let kinds: [(String, HubBind.Kind?)] = [
        ("127.0.0.1", .loopback), ("::1", .loopback), ("100.64.0.1", .tailscale), ("100.127.255.254", .tailscale),
        ("100.128.0.1", nil), ("fd7a:115c:a1e0::1", .tailscale), ("10.0.0.5", .lan), ("172.16.0.1", .lan), ("172.31.255.1", .lan),
        ("172.32.0.1", nil), ("192.168.1.5", .lan), ("8.8.8.8", nil), ("fe80::1", nil), ("0.0.0.0", nil), ("::", nil),
    ]
    for (ip, k) in kinds { check(HubBind.kind(ip) == k, "bind: \(ip) is \(k.map { "\($0)" } ?? "refused")") }

    let local = [HubAddress(host: "127.0.0.1", kind: .loopback, interface: "lo0"),
                 HubAddress(host: "100.101.102.103", kind: .tailscale, interface: "utun4"),
                 HubAddress(host: "192.168.1.5", kind: .lan, interface: "en0")]
    let rules: [(String, Bool, HubServer.StartError?)] = [
        ("127.0.0.1", false, nil), ("127.0.0.1", true, nil),
        ("0.0.0.0", true, .wildcard("0.0.0.0")), ("::", true, .wildcard("::")), ("", true, .wildcard("")),
        ("100.101.102.103", false, .needsTLS("100.101.102.103")), ("100.101.102.103", true, nil),
        ("192.168.1.5", false, .needsTLS("192.168.1.5")), ("192.168.1.5", true, nil),
        ("192.168.1.6", true, .notLocal("192.168.1.6")), ("8.8.8.8", true, .notLocal("8.8.8.8")),
    ]
    for (host, tls, want) in rules {
        check(HubBind.check(host: host, tls: tls, local: local) == want, "bind: \(host) tls=\(tls) -> \(want.map { "\($0)" } ?? "ok")")
    }
    check(HubBind.check(host: "203.0.113.9", tls: true, local: [HubAddress(host: "203.0.113.9", kind: nil, interface: "en1")]) == .publicAddress("203.0.113.9"),
          "bind: a public address on this Mac is refused")
    let real = HubBind.local()
    check(real.contains { $0.host == "127.0.0.1" && $0.kind == .loopback }, "bind: this Mac's list has 127.0.0.1 (\(real.map(\.host)))")
    check(!real.contains { $0.host.hasPrefix("fe80") }, "bind: no link-local addresses offered")

    // A self-signed identity in a temp folder: files 600, loads again with the same fingerprint, memory-only import.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "hktls-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = try HubTLS.selfSigned(in: dir, names: ["127.0.0.1", "mac.example.ts.net"])
    check(id.fingerprint.count == 64 && id.fingerprint.allSatisfy(\.isHexDigit), "tls: SHA-256 fingerprint (\(id.fingerprint.prefix(16))…)")
    check(id.fingerprint == HubTLS.fingerprint(der: id.certificateDER), "tls: fingerprint = SHA-256 of the DER")
    for f in ["key.pem", "cert.pem", "identity.p12"] {
        let mode = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(f).path)[.posixPermissions] as? Int) ?? 0
        check(mode == 0o600, "tls: \(f) mode 600 (\(String(mode, radix: 8)))")
    }
    let again = try HubTLS.load(from: dir)
    check(again?.fingerprint == id.fingerprint, "tls: loads the same identity again")
    check(try HubTLS.load(from: dir.appendingPathComponent("none")) == nil, "tls: no files -> nil")
    let fromPEM = try HubTLS.fromPEM(cert: dir.appendingPathComponent("cert.pem"), key: dir.appendingPathComponent("key.pem"),
                                     into: dir.appendingPathComponent("ts"))
    check(fromPEM.fingerprint == id.fingerprint, "tls: a PEM pair loads as the same certificate")
    // Chrome refuses, with no way past, a certificate whose DNS name is not ASCII (a Mac named "李's MacBook" gave
    // one). Such names are left out; a stored certificate that has one is not loaded, so a new one is made.
    let bad = dir.appendingPathComponent("badname")
    let clean = try HubTLS.selfSigned(in: bad, names: ["127.0.0.1", "李的MacBook-Air.local", "a b.local", "mac-1.local"])
    let cleanText = String(decoding: clean.certificateDER, as: UTF8.self)
    check(!cleanText.contains("MacBook-Air") && !cleanText.contains("a b") && cleanText.contains("mac-1.local"),
          "tls: a non-ASCII or spaced DNS name is left out of the certificate")
    let oldBad = Process()
    oldBad.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    oldBad.arguments = ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-pkeyopt", "ec_param_enc:named_curve",
                        "-nodes", "-keyout", bad.path + "/key.pem", "-out", bad.path + "/cert.pem", "-days", "2", "-subj", "/CN=t",
                        "-addext", "subjectAltName=IP:127.0.0.1,DNS:李的MacBook-Air.local"]
    oldBad.standardError = FileHandle.nullDevice; oldBad.standardOutput = FileHandle.nullDevice
    try oldBad.run(); oldBad.waitUntilExit()
    _ = try HubTLS.fromPEM(cert: bad.appendingPathComponent("cert.pem"), key: bad.appendingPathComponent("key.pem"), into: bad)
    check(try HubTLS.load(from: bad) == nil, "tls: a stored certificate with a non-ASCII DNS name is not loaded (made again)")
    check(try HubTLS.load(from: dir)?.fingerprint == id.fingerprint, "tls: a stored certificate with valid names still loads")

    // An EC pair with explicit curve parameters (LibreSSL's default) would crash the in-memory import: refused first.
    let ex = dir.appendingPathComponent("explicit")
    try FileManager.default.createDirectory(at: ex, withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    p.arguments = ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", ex.path + "/k.pem",
                   "-out", ex.path + "/c.pem", "-days", "2", "-subj", "/CN=t"]
    p.standardError = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    let explicitKey = (try? String(contentsOf: ex.appendingPathComponent("k.pem"), encoding: .utf8)) ?? ""
    var refusedExplicit = false
    do { _ = try HubTLS.fromPEM(cert: ex.appendingPathComponent("c.pem"), key: ex.appendingPathComponent("k.pem"), into: ex.appendingPathComponent("out")) }
    catch HubTLS.Failure.explicitCurve { refusedExplicit = true }
    check(!explicitKey.isEmpty && refusedExplicit, "tls: an EC pair with explicit parameters is refused (no crash)")

    // TLS over loopback: the pinned client gets in; plain ws gets nothing.
    let b = FakeHubBackend(workspaces: [])
    let devices = MemoryDeviceStore()
    devices.add(token: "tok", device: HubDevice(id: "d1", name: "Phone", level: .read))
    let server = HubServer(backend: b, devices: devices, tickInterval: .milliseconds(200))
    let port = try await server.start(host: "127.0.0.1", port: 0, tls: id)
    check(server.running && server.fingerprint == id.fingerprint, "tls: hub listens with TLS on 127.0.0.1:\(port)")

    let pin = PinDelegate(pin: id.fingerprint)
    let session = URLSession(configuration: .ephemeral, delegate: pin, delegateQueue: nil)
    let c = HubTestClient(task: session.webSocketTask(with: URL(string: "wss://127.0.0.1:\(port)/ws")!))
    try? await c.send(#"{"v":1,"type":"hello","id":"h","token":"tok","client":"check","clientVersion":"1"}"#)
    let hello = await c.untilReply()
    check(hello.map(\.type) == ["welcome", "snapshot", "reply"], "tls: wss hello with the pinned certificate (\(hello.map(\.type)))")
    c.close()

    let wrong = PinDelegate(pin: String(repeating: "0", count: 64))
    let ws = URLSession(configuration: .ephemeral, delegate: wrong, delegateQueue: nil)
    let w = HubTestClient(task: ws.webSocketTask(with: URL(string: "wss://127.0.0.1:\(port)/ws")!))
    try? await w.send(#"{"v":1,"type":"ping","id":"p"}"#)
    check(await w.next(2) == nil && wrong.seen == id.fingerprint, "tls: a client with another pin refuses the hub")
    w.close()

    let plain = HubTestClient(port: port)
    try? await plain.send(#"{"v":1,"type":"ping","id":"p"}"#)
    check(await plain.next(2) == nil, "tls: plain ws gets nothing")
    plain.close()
    server.stop()
    session.invalidateAndCancel(); ws.invalidateAndCancel()
}
