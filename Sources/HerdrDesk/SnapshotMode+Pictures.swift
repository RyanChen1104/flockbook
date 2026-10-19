import AppKit
import HerdrKit
import SwiftUI

extension ContentTests {
    /// Pictures from the log: sizes from the ref before they load (the row keeps its height), thumbnails in the owner's
    /// bubble and under a tool group, a bounded cache, and the Quick Look file (mode 600, gone when closed).
    static func pictures() async {
        var failures = 0
        func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("pictures-test: \(n) \(ok ? "ok" : "FAIL")") }
        func solid(_ w: Int, _ h: Int, _ c: NSColor) -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            c.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: .png, properties: [:])!
        }
        func json(_ o: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]), as: UTF8.self) }
        func image(_ d: Data) -> [String: Any] { ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": d.base64EncodedString()]] }

        // Sizes: the bubble's thumbnails are at most 120 pt high, a lone tool picture at most 480 pt (or the column) wide,
        // and neither is drawn larger than its pixels.
        func s(_ c: CGSize) -> String { "\(Int(c.width))x\(Int(c.height))" }
        func ref(_ w: Int, _ h: Int) -> LogImage.Ref { LogImage.Ref(format: .png, width: w, height: h, offset: 0, index: 0) }
        step("thumb 400x200 -> 240x120 (\(s(PictureLayout.thumb(ref(400, 200)))))", s(PictureLayout.thumb(ref(400, 200))) == "240x120")
        step("thumb 2880x1800 -> 192x120", s(PictureLayout.thumb(ref(2880, 1800))) == "192x120")
        step("thumb 100x50 stays 100x50", s(PictureLayout.thumb(ref(100, 50))) == "100x50")
        step("tool 1200x600 -> 480x240 (\(s(PictureLayout.fit(ref(1200, 600), maxWidth: 480))))", s(PictureLayout.fit(ref(1200, 600), maxWidth: 480)) == "480x240")
        step("tool 1200x600 in a 300 pt column -> 300x150", s(PictureLayout.fit(ref(1200, 600), maxWidth: 300)) == "300x150")
        step("tool 32x16 stays 32x16", s(PictureLayout.fit(ref(32, 16), maxWidth: 480)) == "32x16")
        step("a broken size (0 high) draws nothing", s(PictureLayout.thumb(ref(10, 0))) == "0x0")

        // A synthetic log: the owner pastes a red picture, a tool returns a blue one.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "pictures-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.jsonl")
        let red = solid(400, 200, .red), blue = solid(1200, 600, .blue)
        let lines = [
            json(["type": "user", "uuid": "u1", "message": ["role": "user", "content": [["type": "text", "text": "What is wrong here? [Image #1]"], image(red)]]] as [String: Any]),
            json(["type": "assistant", "uuid": "a1", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "shot.png"]]]]] as [String: Any]),
            json(["type": "user", "uuid": "r1", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": [image(blue)]]]]] as [String: Any]),
            json(["type": "assistant", "uuid": "a2", "message": ["role": "assistant", "content": [["type": "text", "text": "The button is cut off."]]]] as [String: Any]),
        ]
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        let log = SessionLog(sessionId: file.path)
        var it = log.snapshots(pollInterval: .milliseconds(20)).makeAsyncIterator()
        var items: [ConversationItem] = []
        for _ in 0..<20 where items.isEmpty { if let s = await it.next(), s.load == .ready { items = s.items } }
        let userRef = items.flatMap(\.images).first
        let toolRef: LogImage.Ref? = items.compactMap { if case .toolChips(let c) = $0.kind { c.flatMap(\.calls).flatMap(\.images).first } else { nil } }.first
        step("log has the owner's and the tool's picture", userRef != nil && toolRef != nil)
        guard let userRef, let toolRef, let url = log.url else { return finish(failures) }

        // The row's height is the same before the picture loads (no log) and after (decoded).
        PictureCache.shared.removeAll()
        func height(_ v: some View) async -> CGFloat {
            let host = NSHostingView(rootView: v.frame(width: 700))
            host.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
            for _ in 0..<6 { try? await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded() }
            return host.fittingSize.height
        }
        let bubble = UserBubble(text: "What is wrong here? [Image #1]", size: .m, images: [userRef])
        let before = await height(bubble), after = await height(bubble.environment(\.logURL, url))
        step("bubble height before load \(before) = after \(after)", before > 120 && abs(before - after) < 0.5)
        var call = ToolCall(id: "t1", toolName: "Read", summary: "shot.png", input: "{}", output: "")
        call.images = [toolRef]
        let chips = ChipGroup(chips: [ToolChip(symbol: "doc", text: "Read a file", calls: [call])], maxWidth: 700)
        let cb = await height(chips), ca = await height(chips.environment(\.logURL, url))
        step("tool group height before load \(cb) = after \(ca), picture 240 high", cb >= 26 + 240 && abs(cb - ca) < 0.5)

        // Decoded once, kept in a bounded cache; a ref that does not match the file loads nothing.
        step("cache is bounded", PictureCache.shared.countLimit > 0 && PictureCache.shared.totalCostLimit > 0)
        let thumb = await PictureCache.shared.load(url: url, ref: userRef, maxPixel: 240)
        step("thumbnail decodes (\(String(describing: thumb?.size)))", thumb != nil)
        step("second ask is a cache hit", PictureCache.shared.cached(url: url, ref: userRef, maxPixel: 240) != nil)
        let wrong = LogImage.Ref(format: .png, width: 9, height: 9, offset: userRef.offset, index: 0)
        step("a stale ref loads nothing", await PictureCache.shared.load(url: url, ref: wrong, maxPixel: 240) == nil)

        // On screen: the red thumbnail right of centre, the blue picture 480 pt wide on the left.
        let view = ZStack { Color(nsColor: .textBackgroundColor); ConversationView(items: items, agentName: "claude", hasLog: true) }
            .environment(\.logURL, url).environment(\.flatGlass, true)
        let (win, _) = offscreen(view, NSSize(width: 900, height: 1100))
        try? await Task.sleep(for: .seconds(1.5))
        let shot = "\(Self.dir)/pictures.png"
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
        capture(win, to: shot)
        win.orderOut(nil)
        if let rep = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: shot))) ?? Data()) {
            var redX: [Int] = [], blueX: [Int] = []
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) { for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.85 && c.greenComponent < 0.35 && c.blueComponent < 0.35 { redX.append(x) }
                if c.blueComponent > 0.85 && c.redComponent < 0.2 && c.greenComponent < 0.35 { blueX.append(x) }
            } }
            let k = CGFloat(rep.pixelsWide) / 900
            let redW = CGFloat((redX.max() ?? 0) - (redX.min() ?? 0)) / k, blueW = CGFloat((blueX.max() ?? 0) - (blueX.min() ?? 0)) / k
            step("owner's picture drawn right of centre, ~240 pt (\(Int(redW)))", !redX.isEmpty && CGFloat(redX.min()!) / k > 450 && abs(redW - 240) < 6)
            step("tool picture drawn on the left, ~480 pt (\(Int(blueW)))", !blueX.isEmpty && CGFloat(blueX.min()!) / k < 200 && abs(blueW - 480) < 6)
        } else { step("window picture", false) }

        // Quick Look gets a private copy: mode 600 in a 700 folder, removed when the preview closes or the next opens.
        let data = LogImage.read(userRef, from: url) ?? Data()
        let a = PictureFiles.write(data, format: .png), b = PictureFiles.write(data, format: .png)
        let mode = b.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? Int }
        let dmode = (try? FileManager.default.attributesOfItem(atPath: PictureFiles.dir.path)[.posixPermissions]) as? Int
        step("preview file is a .png, mode 600 (\(String(mode ?? 0, radix: 8))), folder 700 (\(String(dmode ?? 0, radix: 8)))",
             b?.pathExtension == "png" && b.flatMap { try? Data(contentsOf: $0) } == data && mode == 0o600 && dmode == 0o700)
        step("opening another removes the first", a.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
        if let b { PictureFiles.remove(b) }
        step("closing removes it", b.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
        print("pictures-test: picture \(shot)")
        finish(failures)
    }

    private static func finish(_ failures: Int) {
        print("pictures-test: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        NSApp.terminate(nil)
    }
}
