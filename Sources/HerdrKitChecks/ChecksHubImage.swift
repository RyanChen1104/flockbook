import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import HerdrKit

// Images from a phone (docs/design/remote-access.md 9.1, remote-protocol.md 3.3): type from magic bytes, size checked
// before decoding, always re-encoded without metadata into the hub's own folder; `attach` in parts with caps and a
// rate limit; `send` names finished uploads and keeps every `send` rule.

/// A test image: `w`x`h`, a two-colour pattern, written as `type` with `properties` (EXIF, GPS, orientation …).
func testImage(_ type: UTType, w: Int = 40, h: Int = 20, properties: [CFString: Any] = [:]) -> Data? {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.4, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.3, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h / 2))
    let out = NSMutableData()
    guard let img = ctx.makeImage(), let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, img, properties as CFDictionary)
    return CGImageDestinationFinalize(dest) ? out as Data : nil
}

/// The properties ImageIO reads from a file.
func imageProperties(_ url: URL) -> [String: Any] {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
    return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
}

private func crc32(_ bytes: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xffffffff
    for b in bytes { c ^= UInt32(b); for _ in 0..<8 { c = (c >> 1) ^ (c & 1 == 1 ? 0xedb88320 : 0) } }
    return ~c
}
/// A PNG whose header claims `w`x`h` (valid CRC), followed by one tiny IDAT: a decompression bomb's header.
func bombPNG(w: UInt32, h: UInt32) -> Data {
    func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] { let t = Array(type.utf8); return be(UInt32(body.count)) + t + body + be(crc32(t + body)) }
    let ihdr = be(w) + be(h) + [8, 6, 0, 0, 0]
    return Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] + chunk("IHDR", ihdr) + chunk("IDAT", [0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]) + chunk("IEND", []))
}

@MainActor func checksHubImage() async throws {
    let png = testImage(.png)!, jpeg = testImage(.jpeg)!
    // A 1x1 lossless WebP (ImageIO reads WebP but cannot write it).
    let webp = Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")!
    let heic = testImage(.heic)

    // Type from the first bytes only.
    check(HubImage.kind(png) == .png && HubImage.kind(jpeg) == .jpeg && HubImage.kind(webp) == .webp, "image: PNG, JPEG, WebP told by magic bytes")
    if let heic { check(HubImage.kind(heic) == .heic, "image: HEIC told by its ftyp brand") } else { print("note: this Mac cannot write HEIC; HEIC decode not checked") }
    check(HubImage.kind(testImage(.gif)!) == nil && HubImage.kind(Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8)) == nil
          && HubImage.kind(Data()) == nil && HubImage.kind(Data([0x89, 0x50])) == nil && HubImage.kind(Data("GIF89a".utf8)) == nil,
          "image: GIF, SVG, empty and short data are not taken")
    check(HubImage.kind(Data([0, 0, 0, 0x18] + Array("ftypmp42".utf8) + [0, 0, 0, 0])) == nil, "image: an MP4 (ftyp, not a HEIC brand) is not taken")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hub-image-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Re-encode: metadata gone, orientation applied, a new file of ours.
    let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 47.3769, kCGImagePropertyGPSLatitudeRef: "N",
                                kCGImagePropertyGPSLongitude: 8.5417, kCGImagePropertyGPSLongitudeRef: "E"]
    let tagged = testImage(.jpeg, w: 40, h: 20, properties: [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyOrientation: 6,
                                                            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam"],
                                                            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret note"]])!
    let inProps = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(tagged as CFData, nil)!, 0, nil) as? [String: Any] ?? [:]
    check(inProps[kCGImagePropertyGPSDictionary as String] != nil, "image: the test photo carries GPS")
    if let out = try? HubImage.reencode(tagged, into: dir) {
        let p = imageProperties(out.url)
        check(p[kCGImagePropertyGPSDictionary as String] == nil, "image: GPS gone after re-encode")
        check((p[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFMake as String] == nil
              && (p[kCGImagePropertyExifDictionary as String] as? [String: Any])?[kCGImagePropertyExifUserComment as String] == nil,
              "image: camera make and EXIF comment gone")
        check(out.width == 20 && out.height == 40 && (p[kCGImagePropertyOrientation as String] as? Int ?? 1) == 1,
              "image: orientation applied to the pixels (\(out.width)x\(out.height)), no orientation tag left")
        check(out.url.pathExtension == "jpg" && out.url.lastPathComponent.hasPrefix("remote-") && out.url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL,
              "image: a JPEG becomes remote-<random>.jpg in the hub's folder (\(out.url.lastPathComponent))")
        let mode = (try? FileManager.default.attributesOfItem(atPath: out.url.path)[.posixPermissions] as? Int) ?? 0
        let dmode = (try? FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int) ?? 0
        check(mode == 0o600 && dmode == 0o700, "image: file mode 600, folder 700 (\(String(mode, radix: 8)), \(String(dmode, radix: 8)))")
        check(out.bytes == ((try? Data(contentsOf: out.url).count) ?? -1), "image: reported bytes = file size")
    } else { check(false, "image: a tagged JPEG re-encodes") }
    if let out = try? HubImage.reencode(png, into: dir) {
        check(out.url.pathExtension == "png" && out.width == 40 && out.height == 20, "image: a PNG stays a PNG, same size")
    } else { check(false, "image: a PNG re-encodes") }
    let a = try? HubImage.reencode(png, into: dir), b = try? HubImage.reencode(png, into: dir)
    check(a != nil && b != nil && a?.url != b?.url, "image: every upload gets its own random name")
    check((try? HubImage.reencode(webp, into: dir))?.url.pathExtension == "jpg", "image: a WebP becomes a JPEG")
    if let heic { check((try? HubImage.reencode(heic, into: dir))?.url.pathExtension == "jpg", "image: a HEIC becomes a JPEG") }

    // Polyglot: bytes after the image never reach the output.
    var poly = png; poly.append(Data("PK\u{3}\u{4}<script>alert(1)</script>".utf8))
    if let out = try? HubImage.reencode(poly, into: dir), let bytes = try? Data(contentsOf: out.url) {
        check(bytes.range(of: Data("<script>".utf8)) == nil && bytes.range(of: Data("PK\u{3}\u{4}".utf8)) == nil, "image: trailing polyglot bytes are not in the output")
    } else { check(false, "image: a PNG with trailing bytes re-encodes") }

    // Large: the long side is capped.
    if let big = testImage(.png, w: 5000, h: 100), let out = try? HubImage.reencode(big, into: dir) {
        check(out.width == HubImage.outputSide && out.height < 100, "image: long side capped at \(HubImage.outputSide) (\(out.width)x\(out.height))")
    } else { check(false, "image: a wide PNG re-encodes") }

    // Refused: a bomb header (before decoding), broken data, not an image.
    func failure(_ d: Data) -> HubImage.Failure? { do { _ = try HubImage.reencode(d, into: dir); return nil } catch { return error as? HubImage.Failure } }
    check(failure(bombPNG(w: 100_000, h: 100_000)) == .tooLarge, "image: a 100000x100000 header is refused before decoding")
    check(failure(bombPNG(w: 13_000, h: 10)) == .tooLarge, "image: a side over 12000 is refused")
    check(failure(png.prefix(40)) == .undecodable, "image: a truncated PNG is refused")
    check(failure(Data("hello".utf8)) == .notImage && failure(testImage(.gif)!) == .notImage, "image: text and GIF are not images here")
    check(failure(Data(count: HubImage.maxBytes + 1)) == .tooLarge, "image: over 10 MiB refused")
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    check(files.allSatisfy { $0.hasPrefix("remote-") && !$0.hasSuffix(".tmp") }, "image: no stray or temporary files (\(files.count) files)")

    // Fuzz: mutated PNG, JPEG and WebP bytes (flips, cuts, splices). Each one is refused or becomes a clean new file.
    var rng = XorShift(s: 0x1a2b3c4d)
    let fuzzDir = dir.appendingPathComponent("fuzz", isDirectory: true)
    var outcomes: [String: Int] = [:]
    var fuzzOK = true
    for i in 0..<300 {
        var d = [png, jpeg, webp][i % 3]
        switch rng.next() % 3 {
        case 0: for _ in 0..<(1 + Int(rng.next() % 8)) { let at = Int(rng.next() % UInt64(d.count)); d[at] = UInt8(truncatingIfNeeded: rng.next()) }
        case 1: d = d.prefix(Int(rng.next() % UInt64(d.count)))
        default: let at = Int(rng.next() % UInt64(d.count)); d = d.prefix(at) + Data((0..<64).map { _ in UInt8(truncatingIfNeeded: rng.next()) }) + d.suffix(from: at)
        }
        do {
            let out = try HubImage.reencode(d, into: fuzzDir)
            outcomes["ok", default: 0] += 1
            if out.width < 1 || out.width > HubImage.outputSide || imageProperties(out.url)[kCGImagePropertyGPSDictionary as String] != nil { fuzzOK = false }
        } catch let f as HubImage.Failure { outcomes["\(f)", default: 0] += 1 } catch { fuzzOK = false }
    }
    let fuzzFiles = (try? FileManager.default.contentsOfDirectory(atPath: fuzzDir.path)) ?? []
    check(fuzzOK && fuzzFiles.count == outcomes["ok", default: 0] && fuzzFiles.allSatisfy { $0.hasPrefix("remote-") },
          "image fuzz: 300 mutated images, no crash, one clean file per accepted one (\(outcomes.sorted { $0.key < $1.key }))")

    checksImagePaste()
    try await checksHubAttach(png: png, dir: dir)
}

/// The session side: `attach` parts, caps, the rate limit, `send` with attachments.
@MainActor func checksHubAttach(png: Data, dir: URL) async throws {
    let a = Agent(name: "claude", kind: "claude", status: .idle, sessionId: "s1", title: "Fix")
    let ws = [Workspace(id: "w1", label: "web", tabs: [Tab(id: "w1:t1", label: "build", number: 1,
                        panes: [Pane(id: "w1:p1", terminalId: "term_1", cwd: "/work", agent: a)], status: .idle)])]
    let b = FakeHubBackend(workspaces: ws)
    b.screens["w1:p1"] = "> \n"
    b.imageDirectory = dir.appendingPathComponent("session", isDirectory: true)
    let devices = MemoryDeviceStore()
    devices.add(token: "in", device: HubDevice(id: "d-in", name: "Phone", level: .input))
    devices.add(token: "rd", device: HubDevice(id: "d-rd", name: "Tablet", level: .read))
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let limiter = HubUploadLimiter(now: { now })
    func session(_ token: String) async -> HubSession {
        let s = HubSession(backend: b, devices: devices, uploads: limiter)
        _ = await s.receive(Data(#"{"v":1,"type":"hello","id":"h","token":"\#(token)","client":"t","clientVersion":"1"}"#.utf8))
        return s
    }
    func attach(_ s: HubSession, _ upload: String, _ data: Data, part: Int = 0, parts: Int = 1) async -> [HubMessage] {
        await s.receive(Data(#"{"v":1,"type":"attach","id":"a","upload":"\#(upload)","part":\#(part),"parts":\#(parts),"data":"\#(data.base64EncodedString())"}"#.utf8))
    }
    func send(_ s: HubSession, _ text: String, _ ids: [String]) async -> [HubMessage] {
        let list = ids.map { "\"\($0)\"" }.joined(separator: ",")
        return await s.receive(Data(#"{"v":1,"type":"send","id":"s","pane":"w1:p1","text":"\#(text)","attachments":[\#(list)]}"#.utf8))
    }
    func code(_ ms: [HubMessage]) -> HubError.Code? { if case .reply(let r)? = ms.last { r.error?.code } else { nil } }
    func ok(_ ms: [HubMessage]) -> Bool { if case .reply(let r)? = ms.last { r.ok } else { false } }
    func held() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: b.imageDirectory!.path)) ?? [] }

    let rd = await session("rd")
    check(code(await attach(rd, "x", png)) == .readOnly && held().isEmpty, "attach: a read device gets readOnly, nothing written")

    let s = await session("in")
    let one = await attach(s, "img1", png)
    if case .attached(let at)? = one.first { check(at.upload == "img1" && at.width == 40 && at.height == 20 && at.bytes > 0, "attach: one part -> attached, then ok") }
    else { check(false, "attach: one part -> attached (\(one.map(\.type)))") }
    check(ok(one) && held().count == 1, "attach: the re-encoded file is held")

    // In parts, in order.
    let half = png.count / 2
    check(ok(await attach(s, "img2", png.prefix(half), part: 0, parts: 2)), "attach: part 1 of 2 ok")
    let two = await attach(s, "img2", png.suffix(from: half), part: 1, parts: 2)
    check(ok(two) && two.contains { if case .attached = $0 { true } else { false } }, "attach: part 2 of 2 completes the image")

    // Wrong parts and names: badRequest, nothing kept.
    check(code(await attach(s, "img3", png, part: 1, parts: 2)) == .badRequest, "attach: a part out of order -> badRequest")
    _ = await attach(s, "img4", png.prefix(half), part: 0, parts: 2)
    check(code(await attach(s, "img5", png, part: 0, parts: 1)) == .badRequest, "attach: another upload while one is open -> badRequest")
    check(code(await attach(s, "img4", png.suffix(from: half), part: 1, parts: 2)) == .badRequest, "attach: ... and the open one was dropped")
    check(code(await attach(s, "img6", png, parts: 17)) == .badRequest, "attach: more than 16 parts -> badRequest")
    check(code(await attach(s, "img6", png, parts: 0)) == .badRequest, "attach: 0 parts -> badRequest")
    check(code(await attach(s, "img6", Data(count: HubImage.maxPartBytes + 1), parts: 2)) == .badRequest, "attach: a part over 640 KiB -> badRequest")
    let n1 = code(await attach(s, "../etc", png)), n2 = code(await attach(s, String(repeating: "a", count: 33), png)), n3 = code(await attach(s, "", png))
    check(n1 == .badRequest && n2 == .badRequest && n3 == .badRequest, "attach: a bad upload name -> badRequest")
    check(code(await s.receive(Data(#"{"v":1,"type":"attach","id":"a","upload":"img7","part":0,"parts":1,"data":"%%%not base64"}"#.utf8))) == .badRequest,
          "attach: bad base64 -> badRequest")
    // Malformed attach messages: wrong field types, missing fields, out of range numbers.
    let malformed = [#""part":"0","parts":1,"data":"AA=="#, #""part":0,"parts":"1","data":"AA=="#, #""part":0,"parts":1,"data":5"#,
                     #""part":-1,"parts":1,"data":"AA=="#, #""part":0,"parts":-3,"data":"AA=="#, #""part":0,"parts":99999999999,"data":"AA=="#,
                     #""part":0.5,"parts":1,"data":"AA=="#, #""parts":1,"data":"AA=="#, #""part":0,"parts":1"#, #""part":0,"parts":1,"data":null"#]
    var malformedOK = true
    for (i, m) in malformed.enumerated() {
        let r = await s.receive(Data(#"{"v":1,"type":"attach","id":"m","upload":"mf\#(i)",\#(m)}"#.utf8))
        if code(r) != .badRequest || s.closed { malformedOK = false; print("note: malformed attach \(i) -> \(r)") }
    }
    check(malformedOK, "attach: \(malformed.count) malformed messages -> badRequest, connection stays")
    check(code(await attach(s, "img8", Data("not an image at all".utf8))) == .badRequest, "attach: not an image -> badRequest")
    check(code(await attach(s, "img9", bombPNG(w: 60_000, h: 60_000))) == .badRequest, "attach: a bomb header -> badRequest")
    check(held().count == 2, "attach: refused uploads leave no file (\(held().count) held)")

    // send with attachments: the text and the files, through the backend's send; once only.
    b.sentImages.removeAll()
    check(ok(await send(s, "look", ["img1", "img2"])), "send: text + 2 images ok")
    check(b.sentImages.last?.count == 2 && b.sentImages.last!.allSatisfy { $0.path.hasPrefix(b.imageDirectory!.path) && FileManager.default.fileExists(atPath: $0.path) },
          "send: the backend got the two re-encoded files of the hub's folder")
    check(code(await send(s, "again", ["img1"])) == .badRequest, "send: a sent upload cannot be named again")
    check(code(await send(s, "x", ["nope"])) == .badRequest && b.sentImages.count == 1, "send: an unknown upload -> badRequest, nothing sent")
    check(code(await send(s, "x", ["a", "b", "c", "d", "e"])) == .badRequest, "send: more than 4 attachments -> badRequest")
    _ = await attach(s, "img10", png)
    check(ok(await send(s, "", ["img10"])) && b.sentImages.count == 2, "send: an image with no text is ok")
    check(code(await send(s, "", [])) == .badRequest, "send: no text and no image -> badRequest")

    // A refused send keeps the upload for a retry.
    _ = await attach(s, "img11", png)
    b.screens["w1:p1"] = "Do you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel"
    check(code(await send(s, "now", ["img11"])) == .promptOpen, "send: a prompt open -> promptOpen")
    b.screens["w1:p1"] = "> \n"
    check(ok(await send(s, "now", ["img11"])), "send: after the prompt, the same upload goes")

    // Held cap: a fifth unsent upload drops the oldest and its file.
    let before = held().count
    for i in 0..<5 { _ = await attach(s, "h\(i)", png) }
    check(held().count == before + 4, "attach: at most 4 unsent held (\(held().count - before))")
    let h0 = code(await send(s, "x", ["h0"])), h4 = ok(await send(s, "x", ["h4"]))
    check(h0 == .badRequest && h4, "attach: the oldest was dropped, the newest kept")

    // Closing the connection deletes unsent uploads.
    let unsent = held().count
    s.discard()
    check(held().count == unsent - 3, "close: the 3 unsent files are deleted (\(unsent) -> \(held().count))")

    // Input off on the Mac: nothing taken.
    b.writesEnabled = false
    let off = await session("in")
    check(code(await attach(off, "z", png)) == .readOnly, "attach: Allow input off -> readOnly")
    b.writesEnabled = true

    // Rate limit per device, over its connections (a new window: the attaches above count too).
    now = now.addingTimeInterval(HubUploadLimiter.window + 1)
    let r1 = await session("in"), r2 = await session("in")
    var taken = 0
    for i in 0..<HubUploadLimiter.maxImages { if ok(await attach(i % 2 == 0 ? r1 : r2, "r\(i)", png)) { taken += 1 }; if i % 4 == 3 { r1.discard(); r2.discard() } }
    check(taken == HubUploadLimiter.maxImages, "rate: \(taken) images taken in the window")
    let o1 = code(await attach(r1, "over", png)), o2 = code(await attach(r2, "over2", png))
    check(o1 == .rateLimited && o2 == .rateLimited, "rate: the next image from any connection of the device -> rateLimited")
    let other = HubSession(backend: b, devices: devices, uploads: limiter)
    devices.add(token: "in2", device: HubDevice(id: "d-in2", name: "Pad", level: .input))
    _ = await other.receive(Data(#"{"v":1,"type":"hello","id":"h","token":"in2","client":"t","clientVersion":"1"}"#.utf8))
    check(ok(await attach(other, "fine", png)), "rate: another device is not limited")
    now = now.addingTimeInterval(HubUploadLimiter.window + 1)
    check(ok(await attach(r1, "later", png)), "rate: after the window it works again")
    let bytesLimiter = HubUploadLimiter(now: { now })
    check(bytesLimiter.take(device: "d", bytes: HubUploadLimiter.maxBytes, image: false) && !bytesLimiter.take(device: "d", bytes: 1, image: false),
          "rate: 100 MiB per device in the window")
    r1.discard(); r2.discard(); other.discard()
}

/// Image paths go to the agent as a bracketed paste (Claude Code turns a pasted image path into `[Image #n]`; typed,
/// it stays text). Only paths of files in the image folder; everything else is typed as before.
func checksImagePaste() {
    typealias S = ImagePaste.Segment
    let dir = "/home/a/Library/Caches/HerdrDesk/paste"
    check(ImagePaste.segments("look", directory: dir) == [S.text("look")], "paste: text alone is typed")
    check(ImagePaste.segments("look \(dir)/remote-AB12.jpg", directory: dir) == [.text("look "), .image("\(dir)/remote-AB12.jpg")],
          "paste: text, then the image path pasted")
    check(ImagePaste.segments("\(dir)/A.png \(dir)/remote-B.jpg", directory: dir) == [.image("\(dir)/A.png"), .text(" "), .image("\(dir)/remote-B.jpg")],
          "paste: two images, the space between typed")
    check(ImagePaste.segments("see /tmp/x.png and \(dir)/../x.png", directory: dir) == [.text("see /tmp/x.png and \(dir)/../x.png")],
          "paste: paths outside the folder (or climbing out) stay typed text")
    check(ImagePaste.segments("\(dir)/a.gif \(dir)/sub/a.png", directory: dir) == [.text("\(dir)/a.gif \(dir)/sub/a.png")], "paste: other types and subfolders stay text")
    let spaced = "/home/a b/Library/Caches/HerdrDesk/paste"
    check(ImagePaste.segments("hi '\(spaced)/C.png'", directory: spaced) == [.text("hi "), .image("\(spaced)/C.png")],
          "paste: a quoted path (home with a space) is pasted unquoted")
    let quote = "/home/o'b/paste"
    check(ImagePaste.segments("'/home/o'\\''b/paste/D.png'", directory: quote) == [.image("\(quote)/D.png")], "paste: a quote in the folder name")
    check(ImagePaste.paste("/p/A.png") == "\u{1b}[200~/p/A.png\u{1b}[201~", "paste: bracketed paste markers around the path")
    check(ImagePaste.segments("x \(dir)/A\u{1b}[201~.png", directory: dir).allSatisfy { if case .image = $0 { false } else { true } },
          "paste: a name with control characters is never pasted")
}
