import Foundation
import Network
@testable import HerdrKit

/// Sends raw bytes to 127.0.0.1:`port` and returns what comes back within `seconds` (or until the hub closes).
func rawExchange(port: UInt16, _ bytes: [Data], seconds: Double = 1.5) async -> Data {
    let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let q = DispatchQueue(label: "raw")
    final class Box: @unchecked Sendable { var data = Data(); var done = false; var how = "timeout" }
    let box = Box()
    let t0 = ContinuousClock.now
    c.start(queue: q)
    for b in bytes { c.send(content: b, completion: .idempotent) }
    func read() {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, end, err in
            q.async { if let d { box.data.append(d) }; if end || err != nil { box.done = true; box.how = "end=\(end) err=\(String(describing: err)) after \(ContinuousClock.now - t0)" } else { read() } }
        }
    }
    read()
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while ContinuousClock.now < deadline { if q.sync(execute: { box.done }) { break }; try? await Task.sleep(for: .milliseconds(20)) }
    c.cancel()
    lastHow = q.sync { box.how }
    return q.sync { box.data }
}
/// How the last `rawExchange` read ended (for failure messages).
nonisolated(unsafe) var lastHow = ""

/// A masked client frame.
func clientFrame(_ opcode: UInt8, _ payload: Data, fin: Bool = true, mask: Bool = true) -> Data {
    var f = Data([(fin ? 0x80 : 0) | opcode])
    let m: UInt8 = mask ? 0x80 : 0
    if payload.count < 126 { f.append(m | UInt8(payload.count)) }
    else if payload.count < 65536 { f.append(m | 126); f.append(UInt8(payload.count >> 8)); f.append(UInt8(payload.count & 0xff)) }
    else { f.append(m | 127); for i in (0..<8).reversed() { f.append(UInt8((payload.count >> (8 * i)) & 0xff)) } }
    guard mask else { return f + payload }
    let key: [UInt8] = [0x12, 0x34, 0x56, 0x78]
    f.append(contentsOf: key)
    f.append(contentsOf: payload.enumerated().map { $0.element ^ key[$0.offset % 4] })
    return f
}

let upgradeHead = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"

// The hub's HTTP and WebSocket layer: one origin for the PWA files and the socket.
@MainActor func checksHubHTTP() async throws {
    // Pure parts.
    check(WebSocketFrames.accept(key: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "ws: RFC 6455 accept key")
    let head = HTTPHead.parse(Data("GET /a.js?x=1 HTTP/1.1\r\nHost: h\r\nUpgrade: WebSocket\r\nX-Two: a\r\n\r\n".utf8))
    check(head?.method == "GET" && head?.path == "/a.js" && head?.header("upgrade") == "WebSocket" && head?.header("x-two") == "a", "http: request head parsed (path without query, headers case-insensitive)")
    check(HTTPHead.parse(Data("garbage\r\n\r\n".utf8)) == nil, "http: a bad request line is refused")
    var fr = WebSocketFrames(maxMessage: 64)
    let two = clientFrame(1, Data("hel".utf8), fin: false) + clientFrame(0, Data("lo".utf8))
    let got = fr.feed(two)
    check(got == [.message(Data("hello".utf8))], "ws: two fragments make one message (\(got))")
    var fr2 = WebSocketFrames(maxMessage: 64)
    let split = clientFrame(1, Data("abc".utf8))
    check(fr2.feed(split.prefix(3)).isEmpty && fr2.feed(split.dropFirst(3)) == [.message(Data("abc".utf8))], "ws: a frame split across reads")
    var fr3 = WebSocketFrames(maxMessage: 64)
    check(fr3.feed(clientFrame(1, Data("x".utf8), mask: false)) == [.fail(1002)], "ws: an unmasked client frame closes (1002)")
    var fr4 = WebSocketFrames(maxMessage: 4)
    check(fr4.feed(clientFrame(1, Data("toolong".utf8))) == [.fail(1009)], "ws: a message over the limit closes (1009)")
    var fr5 = WebSocketFrames(maxMessage: 64)
    check(fr5.feed(clientFrame(9, Data("p".utf8)) + clientFrame(8, Data([0x03, 0xe8]))) == [.ping(Data("p".utf8)), .close], "ws: ping and close")
    let out = WebSocketFrames.encode(opcode: 1, Data(repeating: 65, count: 300))
    check(out.prefix(4) == Data([0x81, 126, 0x01, 0x2c]) && out.count == 304, "ws: server frame, 16-bit length, not masked")

    // The server.
    let b = FakeHubBackend(workspaces: [])
    let devices = MemoryDeviceStore()
    devices.add(token: "tok", device: HubDevice(id: "d1", name: "Phone", level: .read))
    let assets = HubWeb.Assets(files: ["index.html": .init(type: "text/html; charset=utf-8", body: Data("<!doctype html><title>t</title>".utf8)),
                                       "app.js": .init(type: "text/javascript; charset=utf-8", body: Data("console.log(1)".utf8))])
    let server = HubServer(backend: b, devices: devices, assets: assets, tickInterval: .milliseconds(200))
    let port = try await server.start(host: "127.0.0.1", port: 0)

    func get(_ path: String, extra: String = "") async -> String {
        String(decoding: await rawExchange(port: port, [Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\(extra)\r\n".utf8)]), as: UTF8.self)
    }
    let index = await get("/")
    check(index.hasPrefix("HTTP/1.1 200") && index.contains("<title>t</title>") && index.lowercased().contains("content-type: text/html"), "http: / serves index.html")
    check(index.lowercased().contains("content-security-policy: default-src 'self'") && index.lowercased().contains("x-content-type-options: nosniff"),
          "http: CSP and nosniff headers")
    let js = await get("/app.js")
    check(js.hasPrefix("HTTP/1.1 200") && js.lowercased().contains("content-type: text/javascript") && js.hasSuffix("console.log(1)"), "http: /app.js")
    check(await get("/nope.js").hasPrefix("HTTP/1.1 404"), "http: unknown file 404")
    check(await get("/../Package.swift").hasPrefix("HTTP/1.1 404"), "http: path traversal 404")
    let post = String(decoding: await rawExchange(port: port, [Data("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n".utf8)]), as: UTF8.self)
    check(post.hasPrefix("HTTP/1.1 405"), "http: POST refused (405)")
    let big = String(decoding: await rawExchange(port: port, [Data(("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000)).utf8)]), as: UTF8.self)
    check(big.hasPrefix("HTTP/1.1 431") || big.isEmpty, "http: an oversized head is refused")

    // WebSocket upgrade by hand: fragments, ping, origin.
    let hello = Data(#"{"v":1,"type":"hello","id":"h","token":"tok","client":"raw","clientVersion":"1"}"#.utf8)
    let raw = await rawExchange(port: port, [Data((upgradeHead + "\r\n").utf8), clientFrame(1, hello.prefix(20), fin: false), clientFrame(0, hello.dropFirst(20)),
                                             clientFrame(9, Data("hi".utf8))])
    let rawText = String(decoding: raw, as: UTF8.self)
    check(rawText.hasPrefix("HTTP/1.1 101") && rawText.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="), "ws: upgrade on /ws (101 + accept)")
    check(rawText.contains("\"welcome\"") && rawText.contains("\"snapshot\""), "ws: a fragmented hello is answered")
    check(raw.range(of: Data([0x8a, 0x02]) + Data("hi".utf8)) != nil, "ws: ping gets pong with the same payload")
    let unmasked = await rawExchange(port: port, [Data((upgradeHead + "\r\n").utf8), clientFrame(1, hello, mask: false)])
    check(unmasked.range(of: Data([0x88, 0x02, 0x03, 0xea])) != nil, "ws: unmasked client frame -> close 1002 (\(unmasked.count) bytes, \(lastHow))")
    let cross = String(decoding: await rawExchange(port: port, [Data((upgradeHead + "Origin: https://evil.example\r\n\r\n").utf8)]), as: UTF8.self)
    check(cross.hasPrefix("HTTP/1.1 403"), "ws: a foreign Origin is refused (403)")
    let same = String(decoding: await rawExchange(port: port, [Data((upgradeHead + "Origin: https://127.0.0.1\r\n\r\n").utf8)]), as: UTF8.self)
    check(same.hasPrefix("HTTP/1.1 101"), "ws: the hub's own Origin is accepted")
    let wrongPath = String(decoding: await rawExchange(port: port, [Data(upgradeHead.replacingOccurrences(of: "/ws", with: "/x").appending("\r\n").utf8)]), as: UTF8.self)
    check(wrongPath.hasPrefix("HTTP/1.1 404"), "ws: upgrade only on /ws (got \(wrongPath.isEmpty ? "nothing" : String(wrongPath.prefix(40)).debugDescription), \(lastHow))")
    server.stop()
}
