import Foundation
@testable import HerdrKit

// Pictures in session logs (LogImage): sizes from the file header, refs on items, bytes read back by line and index.
// The images are headers only, made up here; nothing decodes them.

private func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
private func le24(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff)] }
private func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }

private func png(_ w: Int, _ h: Int) -> Data {
    var b: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
    b += be32(13); b += Array("IHDR".utf8); b += be32(w); b += be32(h); b += [8, 6, 0, 0, 0]; b += be32(0)
    return Data(b)
}

/// A JPEG whose SOF comes after an APP1 segment of `app` bytes (EXIF puts it there), `sof` = 0xC0 baseline, 0xC2 progressive.
private func jpeg(_ w: Int, _ h: Int, app: Int = 600, sof: UInt8 = 0xc0) -> Data {
    var b: [UInt8] = [0xff, 0xd8, 0xff, 0xe1]
    b += be16(app + 2); b += [UInt8](repeating: 0x41, count: app)
    b += [0xff, 0xc4]; b += be16(4); b += [0, 0]   // a DHT before the frame: not a size
    b += [0xff, sof]; b += be16(17); b += [8]; b += be16(h); b += be16(w); b += [3]; b += [UInt8](repeating: 0, count: 9)
    return Data(b)
}

private func riff(_ chunk: String, _ body: [UInt8]) -> Data {
    var b: [UInt8] = Array("RIFF".utf8)
    b += le32(4 + 8 + body.count); b += Array("WEBP".utf8); b += Array(chunk.utf8); b += le32(body.count); b += body
    return Data(b)
}
private func le32(_ v: Int) -> [UInt8] { le16(v & 0xffff) + le16(v >> 16) }
private func webpX(_ w: Int, _ h: Int) -> Data {
    var body: [UInt8] = [0, 0, 0, 0]
    body += le24(w - 1); body += le24(h - 1)
    return riff("VP8X", body)
}
private func webpL(_ w: Int, _ h: Int) -> Data {
    let bits = (w - 1) | (h - 1) << 14
    var body: [UInt8] = [0x2f]
    body += le32(bits); body += [0, 0, 0]
    return riff("VP8L", body)
}
private func webpLossy(_ w: Int, _ h: Int) -> Data {
    var body: [UInt8] = [0, 0, 0, 0x9d, 0x01, 0x2a]
    body += le16(w); body += le16(h); body += [0, 0]
    return riff("VP8 ", body)
}
private func gif(_ w: Int, _ h: Int) -> Data {
    var b: [UInt8] = Array("GIF89a".utf8)
    b += le16(w); b += le16(h); b += [0, 0, 0]
    return Data(b)
}

private func json(_ o: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]), as: UTF8.self) }

@MainActor func checksLogImage() async throws {
    // Sizes from the header, no decode.
    func size(_ d: Data) -> String { LogImage.header(d).map { "\($0.format.rawValue) \($0.width)x\($0.height)" } ?? "nil" }
    check(size(png(1280, 720)) == "png 1280x720", "image header: png \(size(png(1280, 720)))")
    check(size(jpeg(4032, 3024)) == "jpeg 4032x3024", "image header: jpeg after APP1 and DHT \(size(jpeg(4032, 3024)))")
    check(size(jpeg(800, 600, app: 40_000, sof: 0xc2)) == "jpeg 800x600", "image header: progressive jpeg, SOF 40 KB in")
    check(size(webpX(1920, 1080)) == "webp 1920x1080", "image header: webp VP8X \(size(webpX(1920, 1080)))")
    check(size(webpL(300, 200)) == "webp 300x200", "image header: webp VP8L \(size(webpL(300, 200)))")
    check(size(webpLossy(640, 480)) == "webp 640x480", "image header: webp VP8 \(size(webpLossy(640, 480)))")
    check(size(gif(32, 16)) == "gif 32x16", "image header: gif \(size(gif(32, 16)))")
    check(size(Data("not a picture".utf8)) == "nil" && size(Data()) == "nil" && size(Data(png(10, 10).prefix(20))) == "nil"
          && size(Data(jpeg(10, 10).prefix(300))) == "nil" && size(png(0, 10)) == "nil", "image header: junk, cut or empty → nil")
    check(LogImage.header(base64: png(12, 34).base64EncodedString()).map { "\($0.width)x\($0.height)" } == "12x34"
          && LogImage.header(base64: "%%%") == nil, "image header: from base64, reads only the start")

    let shotA = png(1440, 900).base64EncodedString()
    let shotB = jpeg(640, 480).base64EncodedString()

    // Claude Code: the owner's pasted image is an `image` block beside the text.
    do {
        var p = ConversationParser()
        p.feed(line: json(["type": "user", "uuid": "u1", "message": ["role": "user", "content": [
            ["type": "text", "text": "What is wrong here? [Image #1] [Image #2]"],
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": shotA]],
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": shotB]],
        ]]] as [String: Any]), offset: 4_000)
        p.feed(line: json(["type": "user", "uuid": "u2", "message": ["role": "user", "content": [
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": shotA]],
        ]]] as [String: Any]), offset: 9_000)
        let items = p.items()
        check(describe(items) == ["user:What is wrong here? [Image #1] [Image #2]", "user:"], "claude images: user items \(describe(items))")
        let refs = items.first?.images ?? []
        check(refs.map { "\($0.format.rawValue) \($0.width)x\($0.height) @\($0.offset.map(String.init) ?? "-")#\($0.index)" }
              == ["png 1440x900 @4000#0", "jpeg 640x480 @4000#1"], "claude images: refs on the user item \(refs)")
        check(items.last?.images.map(\.index) == [0] && items.last?.images.first?.offset == 9_000, "claude images: a picture alone is a user item")
        check(!"\(items)".contains(shotA.prefix(40)) && !"\(items)".contains(shotB.prefix(40)), "claude images: no base64 in the items")
    }

    // Claude Code: a tool's picture (Read of a .png, a browser screenshot) in tool_result content.
    do {
        var p = ConversationParser()
        p.feed(line: #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"r1","name":"Read","input":{"file_path":"/tmp/x.png"}}]}}"#, offset: 0)
        p.feed(line: json(["type": "user", "uuid": "t1", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "r1", "content": [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": shotA]]]],
        ]]] as [String: Any]), offset: 200)
        let calls = chipCalls(p.items())
        check(calls.first?.images.map { "\($0.width)x\($0.height) @\($0.offset ?? 0)#\($0.index)" } == ["1440x900 @200#0"], "claude images: tool result picture on its call \(calls)")
        check(describe(p.items()) == ["chips:Read a file"], "claude images: a tool picture is no user item \(describe(p.items()))")
        check(!"\(p.items())".contains(shotA.prefix(40)), "claude images: no base64 in the call")
    }

    // Codex: input_image data URLs, in the owner's message and in a tool's output.
    do {
        var p = ConversationParser()
        p.feed(line: json(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [
            ["type": "input_text", "text": "Match this layout"],
            ["type": "input_image", "image_url": "data:image/webp;base64," + webpX(1200, 800).base64EncodedString()],
        ]]] as [String: Any]), offset: 50)
        p.feed(line: json(["type": "response_item", "payload": ["type": "function_call", "name": "view_image", "call_id": "c1", "arguments": "{}"]] as [String: Any]), offset: 900)
        p.feed(line: json(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "c1", "output": [
            ["type": "input_text", "text": "ok"], ["type": "input_image", "image_url": "data:image/jpeg;base64," + shotB],
        ]]] as [String: Any]), offset: 1_000)
        let items = p.items()
        check(items.first?.images.map { "\($0.format.rawValue) \($0.width)x\($0.height) @\($0.offset ?? 0)#\($0.index)" } == ["webp 1200x800 @50#0"],
              "codex images: on the user item \(items.first?.images ?? [])")
        check(chipCalls(items).first?.images.map { "\($0.width)x\($0.height) @\($0.offset ?? 0)#\($0.index)" } == ["640x480 @1000#0"],
              "codex images: tool output picture on its call")
        check(!"\(items)".contains(shotB.prefix(40)), "codex images: no base64 in the items")
    }

    // pi: a tool result's `image` block (data + mimeType). Kept across a branch rebuild.
    do {
        let lines = [
            json(["type": "message", "id": "u1", "parentId": NSNull(), "message": ["role": "user", "content": [["type": "text", "text": "Screenshot it"]]]] as [String: Any]),
            json(["type": "message", "id": "a1", "parentId": "u1", "message": ["role": "assistant", "content": [["type": "toolCall", "id": "k1", "name": "read", "arguments": ["path": "s.png"]]]]] as [String: Any]),
            json(["type": "message", "id": "r1", "parentId": "a1", "message": ["role": "toolResult", "toolCallId": "k1", "content": [
                ["type": "text", "text": "Read image"], ["type": "image", "data": gif(64, 48).base64EncodedString(), "mimeType": "image/gif"]]]] as [String: Any]),
            json(["type": "message", "id": "a2", "parentId": "r1", "message": ["role": "assistant", "content": [["type": "text", "text": "Done."]]]] as [String: Any]),
            json(["type": "message", "id": "a3", "parentId": "r1", "message": ["role": "assistant", "content": [["type": "text", "text": "Retried."]]]] as [String: Any]),
        ]
        var p = ConversationParser()
        var at: UInt64 = 0
        for l in lines { p.feed(line: l, offset: at); at += UInt64(l.utf8.count + 1) }
        let off2 = UInt64(lines[0].utf8.count + lines[1].utf8.count + 2)
        let refs = chipCalls(p.items()).first?.images ?? []
        check(refs.map { "\($0.format.rawValue) \($0.width)x\($0.height) @\($0.offset ?? 0)#\($0.index)" } == ["gif 64x48 @\(off2)#0"],
              "pi images: tool result picture, offset kept after the rebuild \(refs) \(describe(p.items()))")
    }

    // Read back: the line and index give the bytes; nothing else does.
    do {
        let line = json(["type": "user", "uuid": "u1", "message": ["role": "user", "content": [
            ["type": "text", "text": "two"],
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": shotA]],
            ["type": "tool_result", "tool_use_id": "x", "content": [["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": shotB]]]],
        ]]] as [String: Any])
        check(LogImage.data(line: line, index: 0) == png(1440, 900) && LogImage.data(line: line, index: 1) == jpeg(640, 480)
              && LogImage.data(line: line, index: 2) == nil && LogImage.data(line: "{", index: 0) == nil, "image read back: by index, in log order")
        let cx = json(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [
            ["type": "input_image", "image_url": "data:image/gif;base64," + gif(5, 6).base64EncodedString()]]]] as [String: Any])
        check(LogImage.data(line: cx, index: 0) == gif(5, 6), "image read back: codex data URL")
        let remote = json(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [
            ["type": "input_image", "image_url": "https://example.com/a.png"]]]] as [String: Any])
        var p = ConversationParser()
        p.feed(line: remote, offset: 0)
        check(p.items().allSatisfy(\.images.isEmpty) && LogImage.data(line: remote, index: 0) == nil, "image read back: a web URL is never fetched")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "logimg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("s.jsonl")
        let head = #"{"type":"user","uuid":"h","message":{"content":"hi"}}"#
        try Data((head + "\n" + line + "\n").utf8).write(to: file)
        let ref = LogImage.Ref(format: .jpeg, width: 640, height: 480, offset: UInt64(head.utf8.count + 1), index: 1,
                               digest: LogImage.fingerprint(base64: shotB))
        check(LogImage.read(ref, from: file) == jpeg(640, 480), "image read back: from the log file at the line's offset")
        check(LogImage.read(LogImage.Ref(format: .png, width: 1, height: 1, offset: 3, index: 0, digest: 0), from: file) == nil
              && LogImage.read(LogImage.Ref(format: .png, width: 1, height: 1, offset: nil, index: 0, digest: 0), from: file) == nil,
              "image read back: an offset mid-line or none reads nothing")

        // The ref carries the picture's fingerprint: a rewritten log with another picture of the same format and size at
        // the same line and index reads nothing.
        var pf = ConversationParser()
        pf.feed(line: line, offset: 0)
        let fref = pf.items().flatMap(\.images).first
        let otherA = (png(1440, 900) + Data([1, 2, 3])).base64EncodedString()
        check(fref?.digest == LogImage.fingerprint(base64: shotA) && fref?.digest != 0
              && LogImage.fingerprint(base64: shotA) != LogImage.fingerprint(base64: otherA)
              && LogImage.fingerprint(base64: shotA) == LogImage.fingerprint(base64: String(shotA)),
              "image fingerprint: on the ref, differs for other bytes \(String(describing: fref))")
        let refA = LogImage.Ref(format: .png, width: 1440, height: 900, offset: UInt64(head.utf8.count + 1), index: 0,
                                digest: LogImage.fingerprint(base64: shotA))
        let before = LogImage.read(refA, from: file)
        try Data((head + "\n" + line.replacingOccurrences(of: shotA, with: otherA) + "\n").utf8).write(to: file)
        check(before == png(1440, 900) && LogImage.read(refA, from: file) == nil,
              "image fingerprint: a same-size picture rewritten at the same place reads nothing")
        try Data((head + "\n" + line + "\n").utf8).write(to: file)

        // The tailer's refs read back from the file it found (the view gets the file from the store).
        let log = SessionLog(sessionId: file.path)
        check(log.url == nil, "image log url: none before the first read")
        var it = log.snapshots(pollInterval: .milliseconds(20)).makeAsyncIterator()
        var tailed: [ConversationItem] = []
        for _ in 0..<20 where tailed.isEmpty { if let s = await it.next(), s.load == .ready { tailed = s.items } }
        let tref = tailed.flatMap(\.images).first
        check(log.url?.standardizedFileURL == file.standardizedFileURL, "image log url: the file the tailer reads (\(String(describing: log.url)))")
        check(tref.flatMap { LogImage.read($0, from: file) } == png(1440, 900), "image log url: a tailed ref reads back \(String(describing: tref))")
        let st = HerdrStore(session: HerdrSession(name: "x", socketPath: "/nonexistent"))
        check(st.logURL(for: nil) == nil && st.logURL(for: "no-such-session") == nil, "image log url: store has none for an unknown session")
        st.stop()
        try? FileManager.default.removeItem(at: dir)
    }
}
