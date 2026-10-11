import AppKit
import SwiftUI

/// The Settings window, offscreen, in every look it must survive:
///   .build/debug/HerdrDesk --snapshot-settings <dir>
/// -> <dir>/settings-{light,dark,light-reduce,dark-reduce}.png
/// Increase Contrast is not rendered here: offscreen, the high-contrast appearances draw the same pixels as
/// the plain ones. The view uses only system colors and controls, so the system handles it.
/// Own settings store (test isolation), no Dock icon, nothing sent anywhere.
extension SnapshotRunner {
    @MainActor static func runSettings(dir: String) async {
        var failures = 0
        let looks: [(String, NSAppearance.Name, Bool)] = [
            ("light", .aqua, false), ("dark", .darkAqua, false),
            ("light-reduce", .aqua, true), ("dark-reduce", .darkAqua, true),
        ]
        for (name, look, reduce) in looks {
            let host = NSHostingView(rootView: SettingsView(reduceTransparency: reduce ? true : nil))
            let size = host.fittingSize
            let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            win.title = "Flockbook Settings"
            win.appearance = NSAppearance(named: look)
            win.contentView = host
            win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(700))
            let path = "\(dir)/settings-\(name).png"
            ContentTests.capture(win, to: path)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            let ok = bytes > 5_000 && size.width >= 480 && size.width <= 600 && size.height > 200 && size.height < 900
            if !ok { failures += 1 }
            print("snapshot-settings: \(name) \(Int(size.width))x\(Int(size.height)) pt, \(bytes / 1024) KB \(ok ? "ok" : "FAIL")")
            win.orderOut(nil)
        }
        print("snapshot-settings: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        exit(failures == 0 ? 0 : 1)
    }
}
