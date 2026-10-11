import Foundation
@testable import HerdrKit

// Pairing: a one-time offer (secret for the QR, 6 words to type), valid 5 minutes, single use, a few tries; the store
// keeps only the token hash. Stores are a memory store or a file in a temp folder: checks never touch the Keychain.
@MainActor func checksHubPairing() async throws {
    var now = Date(timeIntervalSince1970: 1_000_000)
    let devices = MemoryDeviceStore()
    let pairing = HubPairing(devices: devices, now: { now })

    check(HubPairing.words.count == 256 && Set(HubPairing.words).count == 256, "pairing: 256 distinct words (8 bits each)")
    check(HubPairing.words.allSatisfy { $0.count >= 3 && $0.count <= 6 && $0.allSatisfy { $0.isASCII && $0.isLowercase } }, "pairing: short lowercase ASCII words")
    check(pairing.open == nil, "pairing: no offer until asked")

    let o = pairing.offer()
    check(o.words.count == 6 && o.words.allSatisfy(HubPairing.words.contains), "pairing: offer has 6 list words (\(o.code))")
    check(o.secret.count >= 43 && !o.secret.contains("=") && !o.secret.contains("/") && !o.secret.contains("+"), "pairing: secret is 256-bit base64url")
    check(o.expires == now.addingTimeInterval(300), "pairing: offer lasts 5 minutes")
    check(pairing.offer().secret != o.secret, "pairing: a new offer replaces the old one")
    let o2 = pairing.open!
    check(pairing.redeem(o.secret, name: "Old") == nil, "pairing: the replaced offer's secret is refused")

    // The code, typed loosely.
    let typed = o2.words.map { $0.uppercased() }.joined(separator: " - ")
    guard let got = pairing.redeem(typed, name: "Phone") else { check(false, "pairing: the typed code pairs"); return }
    check(got.device.name == "Phone" && got.device.level == .read, "pairing: new device, level read (input is opt-in)")
    check(got.token.count >= 43 && got.token != o2.secret, "pairing: a fresh 256-bit token")
    check(devices.device(token: got.token)?.id == got.device.id, "pairing: the store knows the token")
    check(devices.hashes == [HubToken.hash(got.token)] && !devices.hashes.contains(got.token), "pairing: the store keeps only the hash")
    check(pairing.open == nil && pairing.redeem(o2.secret, name: "Again") == nil, "pairing: single use")

    // Expiry.
    let o3 = pairing.offer()
    now += 301
    check(pairing.open == nil && pairing.redeem(o3.secret, name: "Late") == nil, "pairing: expired after 5 minutes")

    // Wrong guesses end the offer.
    let o4 = pairing.offer()
    for i in 0..<HubPairing.maxTries { _ = pairing.redeem("wrong guess \(i)", name: "x", source: "peer-\(i)") }
    check(pairing.open == nil && pairing.redeem(o4.secret, name: "Right") == nil, "pairing: \(HubPairing.maxTries) wrong tries end the offer")
    let o5 = pairing.offer()
    _ = pairing.redeem("nope", name: "x")
    check(pairing.redeem(o5.secret, name: "Tab") != nil, "pairing: one wrong try leaves the offer open")
    check(pairing.redeem("", name: "x") == nil, "pairing: empty input is refused")

    // Link for the QR: the secret and the pinned fingerprint go in the fragment (never sent to a server).
    let o6 = pairing.offer()
    let link = o6.link(base: URL(string: "https://mac.example.ts.net:7480")!, fingerprint: "ab12")
    check(link.absoluteString == "https://mac.example.ts.net:7480/#pair=\(o6.secret)&fp=ab12", "pairing: QR link (\(link.absoluteString))")
    check(o6.link(base: URL(string: "https://h:1")!, fingerprint: nil).absoluteString == "https://h:1/#pair=\(o6.secret)", "pairing: link without a fingerprint")
    pairing.cancel()
    check(pairing.open == nil, "pairing: cancel")

    // Store: list, level, revoke.
    check(devices.all.map(\.device.name).sorted() == ["Phone", "Tab"], "pairing: device list")
    check(devices.all.allSatisfy { $0.paired == Date(timeIntervalSince1970: 1_000_000) || $0.paired == Date(timeIntervalSince1970: 1_000_301) }, "pairing: pair date kept")
    devices.setLevel(.input, device: got.device.id)
    check(devices.device(id: got.device.id)?.level == .input, "pairing: level change")
    devices.revoke(device: got.device.id)
    check(devices.device(token: got.token) == nil && devices.all.count == 1, "pairing: revoke")

    // File store: same behavior, survives a reload, file is 0600, holds no token.
    let dir = NSTemporaryDirectory() + "hkpair-\(UUID().uuidString)"
    let url = URL(fileURLWithPath: dir).appendingPathComponent("devices.json")
    let fs = FileDeviceStore(url: url)
    fs.add(token: "secret-token-1", device: HubDevice(id: "d1", name: "Phone", level: .read), paired: now)
    fs.setLevel(.input, device: "d1")
    let reloaded = FileDeviceStore(url: url)
    check(reloaded.device(token: "secret-token-1")?.level == .input, "file store: reload keeps device and level")
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    check(!text.contains("secret-token-1") && text.contains(HubToken.hash("secret-token-1")), "file store: hash only on disk")
    let perms = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
    check(perms == 0o600, "file store: file mode 600 (\(String(perms, radix: 8)))")
    reloaded.revoke(device: "d1")
    check(FileDeviceStore(url: url).all.isEmpty, "file store: revoke persists")
    check(FileDeviceStore(url: URL(fileURLWithPath: dir + "/missing/x.json")).all.isEmpty, "file store: missing file = no devices")
    try? FileManager.default.removeItem(atPath: dir)

    // Over the session: pair before hello, then hello with the new token.
    let b = FakeHubBackend(workspaces: [])
    let s = HubSession(backend: b, devices: devices, pairing: pairing)
    let o7 = pairing.offer()
    let r = await s.receive(Data(#"{"v":1,"type":"pair","id":"p","secret":"\#(o7.secret)","name":"Laptop"}"#.utf8))
    guard case .paired(let pd)? = r.first, r.count == 2, case .reply(let rep) = r[1], rep.ok else { check(false, "session: pair -> paired, reply (\(r.map(\.type)))"); return }
    check(pd.device.name == "Laptop" && pd.device.level == .read && !s.closed, "session: paired, connection stays open")
    let h = await s.receive(Data(#"{"v":1,"type":"hello","id":"h","token":"\#(pd.token)","client":"c","clientVersion":"1"}"#.utf8))
    check(h.map(\.type) == ["welcome", "snapshot", "reply"], "session: hello with the new token")
    let again = await s.receive(Data(#"{"v":1,"type":"pair","id":"p2","secret":"x","name":"y"}"#.utf8))
    if case .reply(let rr)? = again.first { check(rr.error?.code == .badRequest && !s.closed, "session: pair after hello -> badRequest") } else { check(false, "session: pair after hello -> a reply") }

    let s2 = HubSession(backend: b, devices: devices, pairing: pairing)
    let bad = await s2.receive(Data(#"{"v":1,"type":"pair","id":"p","secret":"wrong","name":"z"}"#.utf8))
    if case .reply(let rr)? = bad.first { check(rr.error?.code == .unauthorized && s2.closed, "session: wrong secret -> unauthorized, closed") } else { check(false, "session: wrong secret -> a reply") }
    let s3 = HubSession(backend: b, devices: devices)
    let off = await s3.receive(Data(#"{"v":1,"type":"pair","id":"p","secret":"x","name":"z"}"#.utf8))
    if case .reply(let rr)? = off.first { check(rr.error?.code == .unauthorized && s3.closed, "session: no pairing open -> unauthorized") } else { check(false, "session: no pairing -> a reply") }
}
