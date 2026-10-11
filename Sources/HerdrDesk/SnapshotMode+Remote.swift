import AppKit
import HerdrKit
import SwiftUI

/// Settings > Remote access and its sheets, offscreen, from preview hubs (nothing listens, nothing on disk):
///   .build/debug/HerdrDesk --snapshot-remote <dir>
/// -> <dir>/remote-<state>-<light|dark>.png. Own settings store (test isolation), no Dock icon.
extension SnapshotRunner {
    @MainActor static func runRemote(dir: String) async {
        var failures = 0
        func step(_ what: String, _ ok: Bool) { if !ok { failures += 1 }; print("snapshot-remote: \(ok ? "ok" : "FAIL") \(what)") }
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        let two: [(HubDevice, Date)] = [(HubDevice(id: "d1", name: "Phone", level: .input), day), (HubDevice(id: "d2", name: "Tablet", level: .read), day)]
        let off = RemoteHub.preview(running: false, devices: [], offer: false)
        let on = RemoteHub.preview(running: true, devices: two, offer: false)
        let pairing = RemoteHub.preview(running: true, devices: [], offer: true)

        step("off: nothing listens, no url", !off.enabled && !off.running && off.url == nil)
        step("on: url wss://100.101.102.103:7480 (\(on.url ?? "nil"))", on.url == "wss://100.101.102.103:7480")
        step("on: the default address is the Tailscale one", on.host == "100.101.102.103")
        let link = pairing.pairLink?.absoluteString ?? ""
        step("pairing: QR link https + secret + fingerprint in the fragment (\(link.prefix(48))…)",
             link.hasPrefix("https://100.101.102.103:7480/#pair=") && link.contains("&fp=") && PairSheet.qr(link) != nil)
        step("pairing: 6 words", pairing.offer?.words.count == 6)
        on.setLevel(.read, device: "d1")
        step("devices: level change shows", on.deviceList.first { $0.device.id == "d1" }?.device.level == .read)
        on.setLevel(.input, device: "d1")

        let shots: [(String, AnyView, CGFloat)] = [
            ("settings-off", AnyView(SettingsView(remote: off)), 520),
            ("settings-on", AnyView(SettingsView(remote: on)), 520),
            ("pair", AnyView(PairSheet(hub: pairing)), 380),
            ("devices", AnyView(DevicesSheet(hub: on)), 460),
        ]
        for (name, view, width) in shots {
            for dark in [false, true] {
                let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
                let size = host.fittingSize
                let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                win.contentView = host
                win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(700))
                let path = "\(dir)/remote-\(name)-\(dark ? "dark" : "light").png"
                // The view's own drawing (window-server captures can come back empty, for example with the display asleep).
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                step("\(name)-\(dark ? "dark" : "light") \(Int(size.width))x\(Int(size.height)) pt, \(bytes / 1024) KB",
                     bytes > 5_000 && abs(size.width - width) < 60 && size.height > 100 && size.height < 1000)
                win.orderOut(nil)
                step("\(name): only preview addresses shown", [off, on, pairing].allSatisfy { $0.addresses.map(\.host) == ["127.0.0.1", "100.101.102.103", "192.168.1.20"] })
            }
        }
        print("snapshot-remote: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        exit(failures == 0 ? 0 : 1)
    }
}
