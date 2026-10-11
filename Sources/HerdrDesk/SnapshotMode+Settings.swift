import AppKit
import CoreImage
import SwiftUI

/// The Settings window, offscreen, in every look it must survive:
///   .build/debug/HerdrDesk --snapshot-settings <dir>
/// -> <dir>/settings-<glass>-<light|dark>.png for Glass, Subtle and Opaque, and settings-reduce-<light|dark>.png
/// (Reduce Transparency, through a stand-in flag). Offscreen there is no desktop and a behind-window blur samples
/// nothing, so each still is composed: a stand-in wallpaper, blurred as the material would, under a capture of the
/// Settings window alone. Only this app's own windows are captured, never the screen.
/// Increase Contrast is not rendered here: offscreen, the high-contrast appearances draw the same pixels as
/// the plain ones. The view uses only system colors and controls, so the system handles it.
/// Own settings store (test isolation), no Dock icon, nothing sent anywhere.
extension SnapshotRunner {
    @MainActor static func runSettings(dir: String) async {
        var failures = 0
        let looks: [(String, WindowGlass, Bool)] = [("glass", .full, false), ("subtle", .subtle, false), ("opaque", .off, false), ("reduce", .full, true)]
        for (name, glass, reduce) in looks {
            for dark in [false, true] {
                AppDefaults.store.set(glass.rawValue, forKey: WindowGlass.key)
                // A Settings scene draws WindowSurface through containerBackground(for: .window); a plain NSWindow does not.
                // Its blur is the blurred wallpaper below (offscreen the material view paints solid), so only its tint goes here.
                let surface = reduce ? WindowGlass.off : glass
                let host = NSHostingView(rootView: ZStack {
                    Color(nsColor: .textBackgroundColor).opacity(surface.tint).ignoresSafeArea()
                    SettingsView(reduceTransparency: reduce ? true : nil)
                })
                let size = host.fittingSize
                let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
                win.title = "Flockbook Settings"
                win.titlebarAppearsTransparent = true
                win.isOpaque = false; win.backgroundColor = .clear
                win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                win.contentView = host
                win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(900))
                let path = "\(dir)/settings-\(name)-\(dark ? "dark" : "light").png"
                // The window's own capture must show content: a blank one (no screen-capture permission) is a FAIL,
                // not a wallpaper-only PASS.
                let ink = compose(win, over: wallpaper(win.frame.size, dark: dark), blur: surface != .off, to: path)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                let ok = ink > 0.02 && bytes > 5_000 && size.width >= 480 && size.width <= 600 && size.height > 200 && size.height < 900
                if !ok { failures += 1 }
                print("snapshot-settings: \(name)-\(dark ? "dark" : "light") \(Int(size.width))x\(Int(size.height)) pt, \(bytes / 1024) KB, window \(String(format: "%.1f", ink * 100))% ink \(ok ? "ok" : "FAIL")")
                win.orderOut(nil)
            }
        }
        print("snapshot-settings: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        exit(failures == 0 ? 0 : 1)
    }

    /// The stand-in wallpaper (blurred like the behind-window material when the window is see-through), then the window's
    /// own pixels over it. The capture is of this one window only.
    /// Returns the share of the window capture that is not background (0 = blank capture).
    @discardableResult
    @MainActor private static func compose(_ win: NSWindow, over paper: NSImage, blur: Bool, to path: String) -> Double {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let top = unsafeBitCast(sym, to: Fn.self)(.null, 8, UInt32(win.windowNumber), 1)?.takeRetainedValue(),
              var back = paper.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("snapshot-settings: no window capture (screen-capture permission: \(CGPreflightScreenCaptureAccess()))")
            return 0
        }
        let ink = Pixels(top).ink
        if ink <= 0.02 { print("snapshot-settings: the window capture is blank (screen-capture permission: \(CGPreflightScreenCaptureAccess()))") }
        if blur, let f = CIFilter(name: "CIGaussianBlur") {
            f.setValue(CIImage(cgImage: back).clampedToExtent(), forKey: kCIInputImageKey)
            f.setValue(30, forKey: kCIInputRadiusKey)
            if let out = f.outputImage, let cg = CIContext().createCGImage(out, from: CIImage(cgImage: back).extent) { back = cg }
        }
        let w = top.width, h = top.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return ink }
        let all = CGRect(x: 0, y: 0, width: w, height: h)
        // Rounded like the window, so the corners stay clear.
        ctx.addPath(CGPath(roundedRect: all, cornerWidth: 24 * CGFloat(w) / win.frame.width, cornerHeight: 24 * CGFloat(w) / win.frame.width, transform: nil))
        ctx.clip()
        ctx.draw(back, in: all)
        ctx.resetClip()
        ctx.draw(top, in: all)
        guard let img = ctx.makeImage() else { return ink }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        return ink
    }

    /// A stand-in desktop: soft colour fields with a few hard shapes, so blur and tint both show.
    @MainActor private static func wallpaper(_ size: NSSize, dark: Bool) -> NSImage {
        NSImage(size: size, flipped: false) { r in
            let colors: [NSColor] = dark ? [.systemIndigo, .systemPurple, .systemTeal] : [.systemOrange, .systemPink, .systemTeal]
            NSGradient(colors: colors)?.draw(in: r, angle: 35)
            (dark ? NSColor.black : NSColor.white).withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.width * 0.55, y: r.height * 0.5, width: 180, height: 180)).fill()
            NSColor.systemYellow.setFill()
            NSBezierPath(roundedRect: NSRect(x: 40, y: 60, width: 220, height: 90), xRadius: 20, yRadius: 20).fill()
            return true
        }
    }
}
