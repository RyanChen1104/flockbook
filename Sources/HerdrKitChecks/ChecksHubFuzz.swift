import Foundation
import Network
@testable import HerdrKit

/// A seeded generator, so a failing fuzz run can be repeated.
struct XorShift: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
}

// The hand-written HTTP/WebSocket layer faces the network: malformed and random input must close cleanly, never
// crash, never grow without bound, and never hold a connection open without a paired device.
@MainActor func checksHubFuzz() async throws {
    var rng = XorShift(s: 0x9E37_79B9_7F4A_7C15)
    func bytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }) }

    // Frames: malformed headers.
    func one(_ d: Data, max: Int = 64) -> [WebSocketFrames.Event] { var f = WebSocketFrames(maxMessage: max); return f.feed(d) }
    var rsv = clientFrame(1, Data("x".utf8)); rsv[0] |= 0x40
    check(one(rsv) == [.fail(1002)], "fuzz: RSV bit without an extension -> 1002")
    var op3 = clientFrame(1, Data("x".utf8)); op3[0] = 0x83
    check(one(op3) == [.fail(1002)], "fuzz: unknown opcode -> 1002")
    check(one(clientFrame(0, Data("x".utf8))) == [.fail(1002)], "fuzz: continuation without a start -> 1002")
    check(one(clientFrame(1, Data("a".utf8), fin: false) + clientFrame(1, Data("b".utf8))) == [.fail(1002)], "fuzz: new message inside a fragmented one -> 1002")
    check(one(clientFrame(9, Data("p".utf8), fin: false)) == [.fail(1002)], "fuzz: fragmented control frame -> 1002")
    check(one(clientFrame(9, Data(repeating: 1, count: 126)), max: 1000) == [.fail(1002)], "fuzz: control frame over 125 bytes -> 1002")
    check(one(Data([0x81, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])) == [.fail(1009)], "fuzz: 64-bit length 2^64-1 -> 1009 (no allocation)")
    check(one(Data([0x81, 0xff, 0x80, 0, 0, 0, 0, 0, 0, 0])) == [.fail(1009)], "fuzz: 64-bit length with the top bit -> 1009")
    check(one(Data([0x81, 0xfe, 0xff, 0xff]), max: 100) == [.fail(1009)], "fuzz: 16-bit length over the limit -> 1009 before the payload")
    check(one(clientFrame(1, Data("a".utf8), fin: false) + clientFrame(0, Data(repeating: 2, count: 64))) == [.fail(1009)],
          "fuzz: fragments together over the limit -> 1009")
    var after = WebSocketFrames(maxMessage: 64)
    _ = after.feed(clientFrame(1, Data("x".utf8), mask: false))
    check(after.feed(clientFrame(1, Data("y".utf8))).isEmpty, "fuzz: nothing is read after a failure")

    // Frames: a valid stream split at every point gives the same events; random bytes never crash.
    let stream = clientFrame(1, Data("hel".utf8), fin: false) + clientFrame(9, Data("p".utf8)) + clientFrame(0, Data("lo".utf8))
        + clientFrame(2, Data(repeating: 7, count: 300)) + clientFrame(8, Data([0x03, 0xe8]))
    let whole = one(stream, max: 1000)
    var splitsOK = true
    for cut in 1..<stream.count {
        var f = WebSocketFrames(maxMessage: 1000)
        let ev = f.feed(stream.prefix(cut)) + f.feed(stream.dropFirst(cut))
        if ev != whole { splitsOK = false }
    }
    check(whole.count == 4 && splitsOK, "fuzz: a stream split at each of \(stream.count - 1) points reads the same")
    var byteByByte = WebSocketFrames(maxMessage: 1000)
    check(stream.flatMap { byteByByte.feed(Data([$0])) } == whole, "fuzz: one byte per read reads the same")
    var randomOK = true
    for _ in 0..<2000 {
        var f = WebSocketFrames(maxMessage: 4096)
        var data = bytes(Int.random(in: 0...200, using: &rng))
        if Bool.random(using: &rng), !data.isEmpty { data[0] = (data[0] & 0x8f) }       // valid-looking first byte sometimes
        if data.count > 1, Bool.random(using: &rng) { data[1] |= 0x80 }                 // masked sometimes
        let ev = f.feed(data)
        if ev.filter({ if case .fail = $0 { true } else { false } }).count > 1 { randomOK = false }
    }
    check(randomOK, "fuzz: 2000 random frame inputs, no crash, at most one failure each")

    // Request heads.
    check(HTTPHead.parse(Data([0x47, 0x45, 0x54, 0x20, 0x2f, 0xff, 0xfe, 0x20, 0x48, 0x54, 0x54, 0x50, 0x2f, 0x31, 0x2e, 0x31])) == nil, "fuzz: bad UTF-8 head refused")
    check(HTTPHead.parse(Data("GET  / HTTP/1.1".utf8)) == nil && HTTPHead.parse(Data("GET / HTTP/2".utf8)) == nil
          && HTTPHead.parse(Data("GET x HTTP/1.1".utf8)) == nil && HTTPHead.parse(Data("GET / HTTP/1.1\r\nNoColon".utf8)) == nil,
          "fuzz: malformed request lines and headers refused")
    var headsOK = true
    for _ in 0..<2000 { _ = HTTPHead.parse(bytes(Int.random(in: 0...300, using: &rng))); headsOK = headsOK && true }
    check(headsOK, "fuzz: 2000 random heads, no crash")

    // The server under bad clients.
    let b = FakeHubBackend(workspaces: [])
    let devices = MemoryDeviceStore()
    devices.add(token: "tok", device: HubDevice(id: "d1", name: "Phone", level: .read))
    let server = HubServer(backend: b, devices: devices, assets: HubWeb.Assets(files: ["index.html": .init(type: "text/html", body: Data("ok".utf8))]),
                           tickInterval: .milliseconds(200))
    server.helloTimeout = .milliseconds(600)
    let port = try await server.start(host: "127.0.0.1", port: 0)
    func get() async -> Bool {
        String(decoding: await rawExchange(port: port, [Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)]), as: UTF8.self).hasPrefix("HTTP/1.1 200")
    }

    let badUTF8 = await rawExchange(port: port, [Data("GET /".utf8) + Data([0xc3, 0x28]) + Data(" HTTP/1.1\r\nHost: x\r\n\r\n".utf8)])
    check(String(decoding: badUTF8, as: UTF8.self).hasPrefix("HTTP/1.1 400"), "fuzz: bad UTF-8 in the head -> 400")
    let up = Data((upgradeHead + "\r\n").utf8)
    let badJSON = await rawExchange(port: port, [up, clientFrame(1, Data([0xff, 0xfe, 0x7b]))])
    check(badJSON.range(of: Data("badRequest".utf8)) != nil || badJSON.range(of: Data("unauthorized".utf8)) != nil,
          "fuzz: bad UTF-8 message -> an error reply, no crash")
    let huge = await rawExchange(port: port, [up, Data([0x81, 0xff, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])])
    check(huge.range(of: Data([0x88, 0x02, 0x03, 0xf1])) != nil, "fuzz: huge length on the socket -> close 1009")

    // Slowloris: a head sent one byte at a time never gets past the deadline.
    let slow = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    final class Flag: @unchecked Sendable { var closed = false }
    let flag = Flag()
    slow.stateUpdateHandler = { if case .cancelled = $0 { flag.closed = true } }
    slow.start(queue: .main)
    slow.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, end, err in if end || err != nil { flag.closed = true } }
    let t0 = ContinuousClock.now
    let line = Array("GET / HTTP/1.1\r\nX-Slow: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".utf8)
    var i = 0
    while !flag.closed, ContinuousClock.now - t0 < .seconds(3) {
        slow.send(content: Data([line[i % line.count]]), completion: .idempotent)
        i += 1
        try? await Task.sleep(for: .milliseconds(50))
    }
    let held = ContinuousClock.now - t0
    slow.cancel()
    check(flag.closed && held < .seconds(2), "fuzz: a slow head is closed by the deadline (\(held))")

    // Many idle connections: only a few are held before hello; the rest are refused at once.
    var idle: [NWConnection] = []
    for _ in 0..<(HubServer.maxPending + 20) {
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        c.start(queue: .main)
        idle.append(c)
    }
    try? await Task.sleep(for: .milliseconds(300))
    check(server.connectionCount <= HubServer.maxPending, "fuzz: idle connections capped at \(HubServer.maxPending) (\(server.connectionCount))")
    for c in idle { c.cancel() }
    try? await Task.sleep(for: .milliseconds(900))

    // Connections the hub closes, each followed at once by a new one: a late callback of a closed connection must
    // never close the next one (connection keys are never reused).
    var lost = 0
    for n in 0..<150 {
        // As in the failures seen: a socket held open, then closed by the client.
        _ = await rawExchange(port: port, [n % 3 == 0 ? up + clientFrame(1, Data("x".utf8), mask: false) : up], seconds: 0.05)
        let r = await rawExchange(port: port, [Data((n % 2 == 0 ? "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n" : upgradeHead.replacingOccurrences(of: "/ws", with: "/x") + "\r\n").utf8)], seconds: 0.3)
        if !String(decoding: r, as: UTF8.self).hasPrefix(n % 2 == 0 ? "HTTP/1.1 200" : "HTTP/1.1 404") { lost += 1 }
    }
    check(lost == 0, "fuzz: 150 closed-then-new connection pairs all answered (\(lost) lost)")
    try? await Task.sleep(for: .milliseconds(300))

    // Random garbage on many connections, then the hub still serves and holds nothing.
    for n in 0..<40 { _ = await rawExchange(port: port, [bytes(Int.random(in: 1...3000, using: &rng))], seconds: n % 10 == 0 ? 0.3 : 0.05) }
    for _ in 0..<20 { _ = await rawExchange(port: port, [up, bytes(Int.random(in: 1...3000, using: &rng))], seconds: 0.05) }
    try? await Task.sleep(for: .milliseconds(900))
    check(await get(), "fuzz: the hub still serves after garbage")
    check(server.connectionCount == 0, "fuzz: no connection left open (\(server.connectionCount))")
    server.stop()
}
