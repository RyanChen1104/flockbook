import AppKit
import HerdrKit
import SwiftUI
import CoreImage.CIFilterBuiltins

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

        // The blank guard itself: a one-colour image has no ink, so a blank capture fails.
        let blankCtx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        blankCtx?.setFillColor(.white); blankCtx?.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        step("blank guard: a white image has no ink", blankCtx?.makeImage().map { Pixels($0).ink == 0 } == true)
        // The shape of the blank window captures seen before: one fill with transparent rounded corners.
        let cornerCtx = CGContext(data: nil, width: 1040, height: 880, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        cornerCtx?.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 1040, height: 880), cornerWidth: 24, cornerHeight: 24, transform: nil))
        cornerCtx?.setFillColor(CGColor(gray: 0.96, alpha: 1)); cornerCtx?.fillPath()
        let cornerInk = cornerCtx?.makeImage().map { Pixels($0).ink } ?? 1
        step("blank guard: a blank window with clear corners is blank (\(String(format: "%.2f", cornerInk * 100))% ink)", cornerInk < 0.02)

        // QR: whole pixels per module, black and white only (no grey edge from scaling).
        if let qr = PairSheet.qr(link), let cg = qr.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let px = Pixels(cg)
            let grey = px.count { r, g, b, _ in !((r < 8 && g < 8 && b < 8) || (r > 247 && g > 247 && b > 247)) }
            let gen = CIFilter.qrCodeGenerator(); gen.message = Data(link.utf8); gen.correctionLevel = "M"
            let modules = gen.outputImage?.extent.width ?? 0
            let perModule = modules > 0 ? qr.size.width / modules : 0
            step("QR: \(Int(modules)) modules, \(perModule) pt each, \(cg.width) px for \(Int(qr.size.width)) pt, \(grey) grey pixels",
                 grey == 0 && cg.width == Int(qr.size.width) * 2 && perModule >= 2 && perModule == perModule.rounded())
        } else { step("QR image", false) }

        // Toggles: the values are on; the snapshot only lacks the accent fill. Proof: a toggle bound to the hub draws the
        // same pixels as a constant-on toggle and differs from a constant-off one, and offscreen even the on toggle has no
        // accent (blue) pixels, because the accent fill needs a key window.
        step("values: Remote access on = \(on.enabled), Allow input on = \(AppDefaults.store.object(forKey: AppSettings.allowInputKey) as? Bool ?? true)",
             on.enabled && (AppDefaults.store.object(forKey: AppSettings.allowInputKey) as? Bool ?? true))
        for dark in [false, true] {
            let bound = render(Toggle("x", isOn: Binding(get: { on.enabled }, set: { _ in })).labelsHidden(), dark: dark)
            let yes = render(Toggle("x", isOn: .constant(true)).labelsHidden(), dark: dark)
            let no = render(Toggle("x", isOn: .constant(false)).labelsHidden(), dark: dark)
            let blue = yes.map { Pixels($0).count { r, g, b, _ in Int(b) > Int(r) + 60 && Int(b) > Int(g) + 30 } } ?? -1
            step("toggle \(dark ? "dark" : "light"): bound == on \(bound.map(Pixels.init) == yes.map(Pixels.init)), on != off \(yes.map(Pixels.init) != no.map(Pixels.init)), accent pixels when on: \(blue)",
                 bound.map(Pixels.init) == yes.map(Pixels.init) && yes.map(Pixels.init) != no.map(Pixels.init))
        }

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
                let ink = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil).map { Pixels($0).ink } ?? 0
                step("\(name)-\(dark ? "dark" : "light") \(Int(size.width))x\(Int(size.height)) pt, \(String(format: "%.1f", ink * 100))% ink",
                     ink > 0.02 && abs(size.width - width) < 60 && size.height > 100 && size.height < 1000)
                win.orderOut(nil)
                step("\(name): only preview addresses shown", [off, on, pairing].allSatisfy { $0.addresses.map(\.host) == ["127.0.0.1", "100.101.102.103", "192.168.1.20"] })
            }
        }
        print("snapshot-remote: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        exit(failures == 0 ? 0 : 1)
    }

    /// A view's own drawing (no window-server capture), in a borderless offscreen window.
    @MainActor static func render(_ view: some View, dark: Bool) -> CGImage? {
        let host = NSHostingView(rootView: view.padding(8).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }
}

/// RGBA pixels of an image, for snapshot checks.
struct Pixels: Equatable {
    let width: Int, height: Int
    let data: [UInt8]
    init(_ cg: CGImage) {
        width = cg.width; height = cg.height
        var d = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &d, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        data = d
    }
    func count(_ test: (UInt8, UInt8, UInt8, UInt8) -> Bool) -> Int {
        var n = 0
        for i in stride(from: 0, to: data.count, by: 4) where test(data[i], data[i + 1], data[i + 2], data[i + 3]) { n += 1 }
        return n
    }
    /// Share of pixels that differ from the most common colour (the background; not a corner pixel, which can be a
    /// transparent rounded corner): about 0 for a blank or one-colour image.
    var ink: Double {
        guard data.count >= 4 else { return 0 }
        var seen: [UInt32: Int] = [:]
        for i in stride(from: 0, to: data.count, by: 4 * 7) {
            seen[UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3]), default: 0] += 1
        }
        let bg = seen.max { $0.value < $1.value }!.key
        let (r0, g0, b0, a0) = (Int(bg >> 24), Int(bg >> 16 & 0xff), Int(bg >> 8 & 0xff), Int(bg & 0xff))
        let n = count { r, g, b, a in abs(Int(r) - r0) > 24 || abs(Int(g) - g0) > 24 || abs(Int(b) - b0) > 24 || abs(Int(a) - a0) > 24 }
        return Double(n) / Double(width * height)
    }
}
