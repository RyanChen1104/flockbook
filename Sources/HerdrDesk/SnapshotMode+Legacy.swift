import AppKit
import HerdrKit
import SwiftUI

/// macOS 15 support: the pre-26 look (`LegacyLook`), drawn on 26. Off on a normal launch. On, the pane bars and the
/// toolbar band show the window surface, not the text scrolling under them (26 fades that text at its soft edges).
extension ContentTests {
    static func legacyLook() async {
        var failures = 0
        func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("legacy-look-test: \(n) \(ok ? "ok" : "FAIL")") }
        if #available(macOS 26, *) {
            step("macOS 26, no flag: the 26 look (forced \(LegacyLook.forced))", !LegacyLook.on && !LegacyLook.forced)
        } else {
            step("before macOS 26: the pre-26 look", LegacyLook.on)
        }
        // Stripes 200 pt wide at x 20, centred in a tall scroll: some rows sit under each bar. Right of them: the surface.
        func stripes() -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<120, id: \.self) { _ in Rectangle().fill(Color.primary).frame(width: 200, height: 6) }
                }
                .padding(.leading, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.center)
        }
        let size = NSSize(width: 400, height: 400)
        // Rows of the stripes' column that show a stripe, in [from, to).
        func striped(_ px: (CGFloat, CGFloat) -> NSColor?, _ from: CGFloat, _ to: CGFloat) -> [Int] {
            let surface = px(320, size.height / 2)
            return stride(from: from, to: to, by: 1).filter { y in
                stride(from: CGFloat(24), to: 216, by: 8).contains { !same(px($0, y), surface) }
            }.map { Int($0) }
        }
        for legacy in [true, false] {
            let name = legacy ? "legacy" : "26"
            let bars = stripes()
                .paneBar(.top) { Text("label").font(.caption).padding(.trailing, 10).frame(maxWidth: .infinity, alignment: .trailing).frame(height: 30) }
                .paneBar(.bottom) { Color.clear.frame(height: 50) }
                .softScrollEdges([.top, .bottom])
            let (w1, h1) = offscreen(ZStack { WindowSurface(glass: .off); bars }.environment(\.legacyLook, legacy).environment(\.flatGlass, true), size)
            try? await Task.sleep(for: .milliseconds(800))
            let p1 = "\(dir)/legacy-look-bars-\(name).png"
            capture(w1, to: p1); w1.orderOut(nil)
            let top = stripes().toolbarFade().safeAreaPadding(.top, 40)
            let (w2, h2) = offscreen(ZStack { WindowSurface(glass: .off); top }.environment(\.legacyLook, legacy).environment(\.flatGlass, true), size)
            try? await Task.sleep(for: .milliseconds(800))
            let p2 = "\(dir)/legacy-look-toolbar-\(name).png"
            capture(w2, to: p2); w2.orderOut(nil)
            guard let px1 = pixels(p1, h1), let px2 = pixels(p2, h2) else { step("\(name): pictures", false); continue }
            let mid = striped(px1, 120, 280), underTop = striped(px1, 3, 27), underBottom = striped(px1, size.height - 47, size.height - 3)
            let underToolbar = striped(px2, 3, 37)
            if legacy {
                step("legacy: stripes show between the bars (\(mid.count) rows)", mid.count > 20)
                step("legacy: none under the top bar (rows \(underTop))", underTop.isEmpty)
                step("legacy: none under the bottom bar (rows \(underBottom))", underBottom.isEmpty)
                step("legacy: none under the toolbar band (rows \(underToolbar))", underToolbar.isEmpty)
            } else {
                // 26 fades them at the soft edges; an offscreen window may not draw that effect, so this only reports.
                print("legacy-look-test: 26: striped rows under the top bar \(underTop.count), bottom bar \(underBottom.count), toolbar band \(underToolbar.count)")
            }
        }
        print("legacy-look-test: pictures in \(dir)/legacy-look-*.png")
        print("legacy-look-test: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        NSApp.terminate(nil)
    }
}
