import CryptoKit
import Foundation
@testable import HerdrKit

/// Subscriptions over the hub protocol, the subscription file, the VAPID key file. Temp folders only; never the
/// real hub folder.
@MainActor func checksPushStore() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "fb-push-\(getpid())")
    defer { try? FileManager.default.removeItem(at: dir) }
    func mode(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.posixPermissions] as? Int) ?? -1 }
    let p256 = "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4", auth = "AAECAwQFBgcICQoLDA0ODw"
    let fcm = "https://fcm.googleapis.com/fcm/send/one"

    // VAPID key file: made once, mode 600, the same key on the next load; a broken file is not replaced.
    let keyURL = dir.appending(path: "hub/vapid.key")
    let k1 = try? VAPIDKeyFile.loadOrCreate(at: keyURL)
    check(k1 != nil && mode(keyURL) == 0o600, "push key: made with mode 600 (\(String(mode(keyURL), radix: 8)))")
    check(mode(keyURL.deletingLastPathComponent()) == 0o700, "push key: its folder is 700")
    check((try? VAPIDKeyFile.loadOrCreate(at: keyURL))?.rawRepresentation == k1?.rawRepresentation, "push key: the same key on the next load")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: keyURL.deletingLastPathComponent().path))?.filter { $0.hasSuffix(".tmp") } ?? ["?"]
    check(leftovers.isEmpty, "push key: no temp file left")
    let broken = dir.appending(path: "hub/broken.key")
    try Data("not a key".utf8).write(to: broken)
    check((try? VAPIDKeyFile.loadOrCreate(at: broken)) == nil && (try? Data(contentsOf: broken)) == Data("not a key".utf8),
          "push key: a broken file throws and stays as it is")

    // The store: one per device, only valid subscriptions, mode 600, reloads.
    let url = dir.appending(path: "hub/push.json")
    let store = FilePushStore(url: url)
    check(!store.add(PushSubscription(device: "d1", endpoint: "https://evil.example/x", p256dh: p256, auth: auth)) && store.all.isEmpty,
          "push store: an endpoint off the allow list is not kept")
    check(!store.add(PushSubscription(device: "d1", endpoint: fcm, p256dh: "AAAA", auth: auth)) && store.all.isEmpty, "push store: a bad key is not kept")
    check(store.add(PushSubscription(device: "d1", endpoint: fcm, p256dh: p256, auth: auth)) && mode(url) == 0o600, "push store: kept, file 600")
    store.add(PushSubscription(device: "d1", endpoint: fcm + "2", p256dh: p256, auth: auth))
    check(store.all.map(\.endpoint) == [fcm + "2"], "push store: one per device, the new one replaces the old")
    store.add(PushSubscription(device: "d2", endpoint: fcm, p256dh: p256, auth: auth))
    check(FilePushStore(url: url).all.count == 2, "push store: reloads from the file")
    store.remove(endpoint: fcm)
    check(store.all.map(\.device) == ["d1"], "push store: a gone endpoint is removed")
    store.remove(device: "d1")
    check(store.all.isEmpty && FilePushStore(url: url).all.isEmpty, "push store: removing the device removes its subscription")

    // Over the protocol: welcome carries the key, subscribe binds to the device, a bad endpoint is refused.
    let devices = MemoryDeviceStore()
    devices.add(token: "tok", device: HubDevice(id: "d1", name: "Phone", level: .read))
    let b = FakeHubBackend(workspaces: [])
    let s = HubSession(backend: b, devices: devices)
    func msg(_ j: String) -> Data { Data(j.utf8) }
    func ok(_ ms: [HubMessage]) -> Bool { if case .reply(let r)? = ms.last { r.ok } else { false } }
    func code(_ ms: [HubMessage]) -> HubError.Code? { if case .reply(let r)? = ms.last { r.error?.code } else { nil } }
    let pre = await s.receive(msg(#"{"v":1,"type":"pushSubscribe","id":"p0","endpoint":"\#(fcm)","p256dh":"\#(p256)","auth":"\#(auth)"}"#))
    check(code(pre) == .unauthorized && b.pushes.all.isEmpty, "push hub: subscribe before hello -> unauthorized")
    let s2 = HubSession(backend: b, devices: devices)
    let hello = await s2.receive(msg(#"{"v":1,"type":"hello","id":"h","token":"tok","client":"t","clientVersion":"1"}"#))
    let welcome = hello.compactMap { if case .welcome(let w) = $0 { w } else { nil } }.first
    check(welcome?.pushKey != nil && welcome?.pushKey == b.pushKey, "push hub: welcome carries the push key")
    let sub = await s2.receive(msg(#"{"v":1,"type":"pushSubscribe","id":"p1","endpoint":"\#(fcm)","p256dh":"\#(p256)","auth":"\#(auth)"}"#))
    check(ok(sub) && b.pushes.all.map(\.device) == ["d1"], "push hub: a read-level device subscribes, bound to its device id")
    func welcomeOf(_ ms: [HubMessage]) -> HubWelcome? { ms.compactMap { if case .welcome(let w) = $0 { w } else { nil } }.first }
    check(welcome?.pushOn == false, "push hub: welcome says this device has no subscription yet")
    let again = await HubSession(backend: b, devices: devices).receive(msg(#"{"v":1,"type":"hello","id":"h","token":"tok","client":"t","clientVersion":"1"}"#))
    check(welcomeOf(again)?.pushOn == true, "push hub: the next welcome says it has one (the Mac did not remove it)")
    let bad = await s2.receive(msg(#"{"v":1,"type":"pushSubscribe","id":"p2","endpoint":"https://evil.example/x","p256dh":"\#(p256)","auth":"\#(auth)"}"#))
    check(code(bad) == .badRequest && b.pushes.all.map(\.endpoint) == [fcm], "push hub: an endpoint off the allow list -> badRequest, nothing changed")
    let un = await s2.receive(msg(#"{"v":1,"type":"pushUnsubscribe","id":"p3","endpoint":"\#(fcm)"}"#))
    check(ok(un) && b.pushes.all.isEmpty, "push hub: unsubscribe removes it")
    let after = await HubSession(backend: b, devices: devices).receive(msg(#"{"v":1,"type":"hello","id":"h","token":"tok","client":"t","clientVersion":"1"}"#))
    check(welcomeOf(after)?.pushOn == false, "push hub: removed -> the next welcome says so (the page drops its own)")
    b.pushKey = nil
    let off = await s2.receive(msg(#"{"v":1,"type":"pushSubscribe","id":"p4","endpoint":"\#(fcm)","p256dh":"\#(p256)","auth":"\#(auth)"}"#))
    check(code(off) == .failed && b.pushes.all.isEmpty, "push hub: no push key -> failed, nothing kept")
}
