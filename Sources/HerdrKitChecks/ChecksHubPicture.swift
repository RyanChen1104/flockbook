import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import HerdrKit

// Pictures on remote devices (remote-protocol.md 3.4): the hub sends no picture with the conversation, only each one's
// size. A device that watches the pane asks for one by item and index and gets a small JPEG in parts; the full picture
// only on request. Read back from the log (digest checked), re-encoded without metadata.

/// `w`x`h` of seeded noise in 2x2 blocks: a picture that does not compress small.
func noisyImage(_ type: UTType, w: Int, h: Int, seed: UInt64 = 1) -> Data? {
    var px = [UInt8](repeating: 255, count: w * h * 4)
    var s = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    func next() -> UInt8 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return UInt8(truncatingIfNeeded: s) }
    for y in stride(from: 0, to: h, by: 2) {
        for x in stride(from: 0, to: w, by: 2) {
            let r = next(), g = next(), b = next()
            for yy in y..<min(y + 2, h) { for xx in x..<min(x + 2, w) { let i = (yy * w + xx) * 4; px[i] = r; px[i + 1] = g; px[i + 2] = b } }
        }
    }
    let out = NSMutableData()
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let img = ctx.makeImage(), let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, img, nil)
    return CGImageDestinationFinalize(dest) ? out as Data : nil
}

/// A Claude Code log with pictures: the owner's message with `user` pictures, then a Read call whose result has `tool`
/// pictures, then `tail` assistant lines. The items as the parser reads the file (refs with real offsets).
func pictureLog(_ file: URL, user: [Data], tool: [Data], tail: Int = 0, text: String = "What is wrong here?") throws -> [ConversationItem] {
    func json(_ o: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]), as: UTF8.self) }
    func block(_ d: Data) -> [String: Any] {
        let mime = LogImage.header(d).map { "image/\($0.format.rawValue)" } ?? "image/png"
        return ["type": "image", "source": ["type": "base64", "media_type": mime, "data": d.base64EncodedString()]]
    }
    var lines = [json(["type": "user", "uuid": "pic-user", "message": ["role": "user", "content": [["type": "text", "text": text]] + user.map(block)]] as [String: Any])]
    if !tool.isEmpty {
        lines.append(#"{"type":"assistant","uuid":"pic-call","message":{"content":[{"type":"tool_use","id":"pic-r1","name":"Read","input":{"file_path":"shot.png"}}]}}"#)
        lines.append(json(["type": "user", "uuid": "pic-result", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "pic-r1", "content": tool.map(block)]]]] as [String: Any]))
    }
    for i in 0..<tail {
        lines.append(json(["type": "assistant", "uuid": "pic-tail-\(i)", "message": ["content": [["type": "text", "text":
            "Line \(i + 1). The picture shows the layout of the settings page; the second column wraps on a narrow window."]]]] as [String: Any]))
    }
    var p = ConversationParser(), offset: UInt64 = 0, body = Data()
    for l in lines {
        p.feed(line: l, offset: offset)
        body += Data((l + "\n").utf8)
        offset += UInt64(l.utf8.count + 1)
    }
    try body.write(to: file)
    return p.items()
}

@MainActor func checksHubPicture() async throws {
    func msg(_ json: String) -> Data { Data(json.utf8) }
    func reply(_ ms: [HubMessage]) -> HubReply? { ms.last.flatMap { if case .reply(let r) = $0 { r } else { nil } } }
    func code(_ ms: [HubMessage]) -> HubError.Code? { reply(ms)?.error?.code }
    func parts(_ ms: [HubMessage]) -> [HubPicturePart] { ms.compactMap { if case .picturePart(let p) = $0 { p } else { nil } } }
    func joined(_ ps: [HubPicturePart]) -> Data { ps.reduce(into: Data()) { $0 += Data(base64Encoded: $1.data) ?? Data() } }
    func side(_ d: Data) -> (Int, Int)? { LogImage.header(d).map { ($0.width, $0.height) } }

    // The messages.
    do {
        let c = ClientMessage(id: "c1", body: .picture(pane: "w1:p1", item: "i1", index: 2, full: true))
        check((try? Hub.decodeClient(Hub.encode(c))) == c, "picture: client message round trip")
        check((try? Hub.decodeClient(msg(#"{"v":1,"type":"picture","id":"c2","pane":"w1:p1","item":"i1","index":0}"#)))?.body
              == .picture(pane: "w1:p1", item: "i1", index: 0, full: false), "picture: full is false when absent")
        check(Hub.clientTypes.contains("picture") && Hub.hubTypes.contains("picturePart"), "picture: a client and a hub type")
        let part = HubPicturePart(re: "c1", pane: "w1:p1", item: "i1", index: 2, full: true, part: 0, parts: 3, mime: "image/jpeg",
                                  width: 800, height: 600, data: "AAEC")
        let wire = (try? Hub.encode(HubMessage.picturePart(part))) ?? Data()
        let obj = (try? JSONSerialization.jsonObject(with: wire)) as? [String: Any] ?? [:]
        check(obj["type"] as? String == "picturePart" && obj["mime"] as? String == "image/jpeg" && obj["v"] as? Int == 1,
              "picture: hub part has type picturePart and mime \(String(decoding: wire, as: UTF8.self))")
        check((try? Hub.decodeHub(wire)) == .picturePart(part), "picture: hub part round trip")
    }

    // Items carry each picture's size only, never bytes; the setting off: none.
    do {
        var user = ConversationItem(id: "u", kind: .userText("look"))
        user.images = [LogImage.Ref(format: .png, width: 1440, height: 900, offset: 0, index: 0, digest: 7),
                       LogImage.Ref(format: .jpeg, width: 640, height: 480, offset: 0, index: 1, digest: 8)]
        var a = ToolCall(id: "r1", toolName: "Read", summary: "a.png", input: "{}", output: "")
        a.images = [LogImage.Ref(format: .png, width: 10, height: 20, offset: 5, index: 0, digest: 9)]
        var b = ToolCall(id: "r2", toolName: "Read", summary: "b.png", input: "{}", output: "")
        b.images = [LogImage.Ref(format: .gif, width: 30, height: 40, offset: 9, index: 0, digest: 10)]
        let tools = ConversationItem(id: "t", kind: .toolChips([ToolChip(symbol: "doc", text: "Read 1 file", calls: [a]), ToolChip(symbol: "doc", text: "Read", calls: [b])]))
        check(HubItem(user).images == [HubPicture(width: 1440, height: 900), HubPicture(width: 640, height: 480)], "picture: user item has the sizes")
        check(HubItem(tools).images == [HubPicture(width: 10, height: 20), HubPicture(width: 30, height: 40)], "picture: tool pictures in call order")
        check(Hub.pictures(of: tools).map(\.digest) == [9, 10] && Hub.pictures(of: user).map(\.digest) == [7, 8], "picture: index = place in the item's list")
        check(HubItem(user, pictures: false).images == nil && HubItem(ConversationItem(id: "x", kind: .userText("hi"))).images == nil,
              "picture: setting off or none -> no images")
        let wire = String(decoding: (try? Hub.encode(HubItem(ConversationItem(id: "x", kind: .assistantText("hi"))))) ?? Data(), as: UTF8.self)
        check(!wire.contains("images"), "picture: no images key without pictures \(wire)")
    }

    // Encoding: a small preview, the full picture on request, parts under the part size.
    let big = noisyImage(.png, w: 4800, h: 1600)!
    do {
        let p = HubImage.preview(big)
        check(p.map { HubImage.kind($0.data) == .jpeg && max($0.width, $0.height) <= HubImage.previewSide && $0.data.count <= HubImage.previewBytes } == true,
              "picture: preview is a JPEG, long side <= \(HubImage.previewSide), <= \(HubImage.previewBytes / 1024) KiB (\(p.map { "\($0.width)x\($0.height) \($0.data.count)" } ?? "nil"))")
        check(p.flatMap { side($0.data) }.map { $0.0 == p!.width && $0.1 == p!.height } == true, "picture: preview size as reported")
        let f = HubImage.full(big)
        check(f.map { HubImage.kind($0.data) == .jpeg && $0.width == HubImage.outputSide && $0.data.count <= HubImage.maxBytes } == true,
              "picture: full is a JPEG, long side \(HubImage.outputSide) (\(f.map { "\($0.width)x\($0.height) \($0.data.count)" } ?? "nil"))")
        let gif = HubImage.preview(testImage(.gif, w: 300, h: 200)!)
        check(gif.map { $0.width == 300 && $0.height == 200 && HubImage.kind($0.data) == .jpeg } == true, "picture: a GIF from a log becomes a JPEG")
        check(HubImage.preview(Data("not a picture".utf8)) == nil && HubImage.preview(bombPNG(w: 60_000, h: 60_000)) == nil, "picture: junk and a bomb -> nil")
        let tagged = testImage(.jpeg, w: 40, h: 20, properties: [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.3]])!
        let clean = HubImage.preview(tagged).map { CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData($0.data as CFData, nil)!, 0, nil) as? [String: Any] ?? [:] }
        check(clean != nil && clean?[kCGImagePropertyGPSDictionary as String] == nil, "picture: no GPS in the preview")
        let data = f?.data ?? Data()
        let ps = HubImage.parts(data)
        check(ps.count > 1 && ps.allSatisfy { $0.count <= HubImage.maxPartBytes } && ps.reduce(Data(), +) == data,
              "picture: \(ps.count) parts of at most \(HubImage.maxPartBytes / 1024) KiB join back")
        check(HubImage.parts(Data()).isEmpty, "picture: no parts of nothing")
    }

    // The session: only a watching device, only while the setting is on, the log's own picture.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hub-picture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("s1.jsonl")
    let shot = noisyImage(.png, w: 1600, h: 1200, seed: 2)!, small = testImage(.jpeg, w: 300, h: 200)!
    let items = try pictureLog(file, user: [small, shot], tool: [testImage(.png, w: 50, h: 40)!])
    let userID = items.first?.id ?? "", toolID = items.first { if case .toolChips = $0.kind { true } else { false } }?.id ?? ""
    check(items.first?.images.count == 2 && !toolID.isEmpty, "picture: the test log has a user item with 2 pictures and a tool item (\(items.map(\.id)))")

    let devices = MemoryDeviceStore()
    devices.add(token: "tok-read", device: HubDevice(id: "d-read", name: "Phone", level: .read), paired: Date())
    func world() -> FakeHubBackend {
        let a = Agent(name: "claude", kind: "claude", status: .idle, sessionId: "s1", title: "Look")
        let b = FakeHubBackend(workspaces: [Workspace(id: "w1", label: "web", tabs: [Tab(id: "w1:t1", label: "t", number: 1,
                               panes: [Pane(id: "w1:p1", terminalId: "term_1", cwd: "/work", agent: a)], status: .idle)])])
        b.items["s1"] = items
        b.logURLs["s1"] = file
        return b
    }
    func session(_ b: FakeHubBackend) async -> HubSession {
        let s = HubSession(backend: b, devices: devices)
        _ = await s.receive(msg(#"{"v":1,"type":"hello","id":"h","token":"tok-read","client":"test","clientVersion":"1"}"#))
        return s
    }
    func ask(_ s: HubSession, _ id: String, item: String, index: Int, full: Bool = false) async -> [HubMessage] {
        await s.receive(msg(#"{"v":1,"type":"picture","id":"\#(id)","pane":"w1:p1","item":"\#(item)","index":\#(index),"full":\#(full)}"#))
    }

    do {
        let b = world()
        let s = await session(b)
        check(code(await ask(s, "c1", item: userID, index: 0)) == .badRequest, "picture: not watching -> badRequest")
        let w = await s.receive(msg(#"{"v":1,"type":"watch","id":"w","pane":"w1:p1"}"#))
        let conv = w.compactMap { if case .conversation(let c) = $0 { c } else { nil } }.first
        check(conv?.items.first?.images == [HubPicture(width: 300, height: 200), HubPicture(width: 1600, height: 1200)],
              "picture: the watched conversation names the sizes \(String(describing: conv?.items.first?.images))")
        check(!String(decoding: (try? Hub.encode(HubMessage.conversation(conv!))) ?? Data(), as: UTF8.self).contains(small.base64EncodedString().prefix(32)),
              "picture: no picture bytes in the conversation")

        // A read device gets a preview: parts that join to a JPEG of the reported size.
        let out = await ask(s, "c2", item: userID, index: 1)
        let ps = parts(out), data = joined(ps)
        check(reply(out)?.ok == true && !ps.isEmpty && ps.allSatisfy { $0.re == "c2" && $0.parts == ps.count && $0.mime == "image/jpeg" && !$0.full }
              && ps.map(\.part) == Array(0..<ps.count), "picture: preview parts in order, then ok (\(ps.count) parts, \(String(describing: reply(out))))")
        check(HubImage.kind(data) == .jpeg && side(data).map { $0.0 == ps.first?.width && $0.1 == ps.first?.height && max($0.0, $0.1) <= 1024 } == true,
              "picture: preview joins to a JPEG of the reported size (\(String(describing: side(data))))")
        let full = await ask(s, "c3", item: userID, index: 1, full: true)
        let fd = joined(parts(full))
        check(reply(full)?.ok == true && parts(full).count > 1 && parts(full).allSatisfy(\.full) && side(fd).map { $0 == (1600, 1200) } == true,
              "picture: full picture in \(parts(full).count) parts at 1600x1200 (\(String(describing: side(fd))))")
        let tool = await ask(s, "c4", item: toolID, index: 0)
        check(reply(tool)?.ok == true && side(joined(parts(tool))).map { $0 == (50, 40) } == true, "picture: a tool picture by its item and index")

        let c5 = code(await ask(s, "c5", item: userID, index: 2)), c6 = code(await ask(s, "c6", item: "nope", index: 0))
        let c7 = code(await ask(s, "c7", item: userID, index: -1))
        check(c5 == .notFound && c6 == .notFound && c7 == .notFound, "picture: unknown item or index -> notFound")
        b.remotePictures = false
        check(code(await ask(s, "c8", item: userID, index: 0)) == .failed, "picture: setting off -> failed")
        b.remotePictures = true
        b.logURLs["s1"] = nil
        check(code(await ask(s, "c9", item: userID, index: 0)) == .notFound, "picture: no log -> notFound")
        b.logURLs["s1"] = file
        _ = await s.receive(msg(#"{"v":1,"type":"unwatch","id":"u","pane":"w1:p1"}"#))
        check(code(await ask(s, "c10", item: userID, index: 0)) == .badRequest, "picture: after unwatch -> badRequest")
    }

    // The setting off: the conversation names no pictures.
    do {
        let b = world(); b.remotePictures = false
        let s = await session(b)
        let w = await s.receive(msg(#"{"v":1,"type":"watch","id":"w","pane":"w1:p1"}"#))
        let conv = w.compactMap { if case .conversation(let c) = $0 { c } else { nil } }.first
        check(conv != nil && conv!.items.allSatisfy { $0.images == nil }, "picture: setting off -> no sizes in the conversation")
    }

    // A rewritten log: the ref's digest no longer matches, nothing is sent.
    do {
        let other = dir.appendingPathComponent("other.jsonl")
        _ = try pictureLog(other, user: [testImage(.jpeg, w: 300, h: 200)!, noisyImage(.png, w: 1600, h: 1200, seed: 3)!], tool: [])
        let b = world(); b.logURLs["s1"] = other
        let s = await session(b)
        _ = await s.receive(msg(#"{"v":1,"type":"watch","id":"w","pane":"w1:p1"}"#))
        let out = await ask(s, "c1", item: userID, index: 1)
        check(code(out) == .notFound && parts(out).isEmpty, "picture: another picture at the same place -> notFound, no parts")
    }

    // Checked again after encoding: unwatched, removed, setting off, or another session meanwhile -> no parts.
    do {
        let b = world()
        let s = await session(b)
        _ = await s.receive(msg(#"{"v":1,"type":"watch","id":"w","pane":"w1:p1"}"#))
        s.afterEncode = { _ = await s.receive(msg(#"{"v":1,"type":"unwatch","id":"u","pane":"w1:p1"}"#)) }
        let out = await ask(s, "c1", item: userID, index: 0)
        check(reply(out)?.ok == false && parts(out).isEmpty, "picture: unwatched while encoding -> no parts (\(String(describing: reply(out))))")

        let s2 = await session(b)
        _ = await s2.receive(msg(#"{"v":1,"type":"watch","id":"w","pane":"w1:p1"}"#))
        s2.afterEncode = { b.remotePictures = false }
        let off = await ask(s2, "c2", item: userID, index: 0)
        check(code(off) == .failed && parts(off).isEmpty, "picture: setting turned off while encoding -> no parts")
        b.remotePictures = true

        s2.afterEncode = { b.workspaces[0].tabs[0].panes[0].agent?.sessionId = "s2" }
        let moved = await ask(s2, "c3", item: userID, index: 0)
        check(reply(moved)?.ok == false && parts(moved).isEmpty, "picture: another session in the pane while encoding -> no parts")
        b.workspaces[0].tabs[0].panes[0].agent?.sessionId = "s1"

        s2.afterEncode = { devices.revoke(device: "d-read") }
        let gone = await ask(s2, "c4", item: userID, index: 0)
        check(code(gone) == .unauthorized && parts(gone).isEmpty && s2.closed, "picture: device removed while encoding -> unauthorized, closed")
    }
}
