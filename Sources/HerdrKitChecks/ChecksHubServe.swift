import Foundation
import HerdrKit

// Remote access through Tailscale Serve: the hub listens on 127.0.0.1 only, Tailscale ends HTTPS at
// https://<machine>.<tailnet>.ts.net:<port> and passes the request on. Every request then comes from 127.0.0.1,
// so loopback must give no trust: the token is still needed, and the socket takes only the ts.net page's Origin.
@MainActor func checksHubServe() async throws {
    // The status of Tailscale (`tailscale status --json`), synthetic.
    let statusJSON = Data("""
    {"BackendState":"Running","CertDomains":["mac.example.ts.net"],"MagicDNSSuffix":"example.ts.net",
     "CurrentTailnet":{"Name":"x","MagicDNSSuffix":"example.ts.net","MagicDNSEnabled":true},
     "Self":{"DNSName":"mac.example.ts.net.","HostName":"mac","OS":"macOS","Online":true},
     "Peer":{"k1":{"DNSName":"phone.example.ts.net.","HostName":"phone","OS":"android","Online":true},
             "k2":{"DNSName":"pad.example.ts.net.","HostName":"pad","OS":"iOS","Online":false},
             "k3":{"DNSName":"box.example.ts.net.","HostName":"box","OS":"linux","Online":true}}}
    """.utf8)
    let s = TailscaleSetup.Status.parse(statusJSON)
    check(s?.signedIn == true && s?.dnsName == "mac.example.ts.net" && s?.httpsReady == true,
          "tailscale: status read (signed in, name without the last dot, MagicDNS + HTTPS on)")
    check(s?.phones.map(\.name) == ["pad", "phone"] && s?.phones.first?.online == false, "tailscale: phones and tablets among the peers (\(s?.phones.map(\.name) ?? []))")
    let noCert = Data(#"{"BackendState":"Running","CertDomains":null,"CurrentTailnet":{"MagicDNSEnabled":true},"Self":{"DNSName":"mac.example.ts.net."}}"#.utf8)
    check(TailscaleSetup.Status.parse(noCert)?.httpsReady == false, "tailscale: no certificate domains -> HTTPS not ready")
    let noDNS = Data(#"{"BackendState":"Running","CertDomains":["mac.example.ts.net"],"CurrentTailnet":{"MagicDNSEnabled":false},"Self":{"DNSName":"mac.example.ts.net."}}"#.utf8)
    check(TailscaleSetup.Status.parse(noDNS)?.httpsReady == false, "tailscale: MagicDNS off -> not ready")
    let login = Data(#"{"BackendState":"NeedsLogin","Self":{"DNSName":""}}"#.utf8)
    check(TailscaleSetup.Status.parse(login)?.signedIn == false, "tailscale: NeedsLogin -> not signed in")
    check(TailscaleSetup.Status.parse(Data("not json".utf8)) == nil, "tailscale: bad output -> nil")

    // The serve config (`tailscale serve status --json`): only our port, only our handler.
    let p = TailscaleSetup.servePort, local = TailscaleSetup.localPort
    let name = "mac.example.ts.net"
    let others = #""443":{"HTTPS":true}"#, otherWeb = #""mac.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:47380"}}}"#
    let ours = Data(#"{"TCP":{\#(others),"\#(p)":{"HTTPS":true}},"Web":{\#(otherWeb),"\#(name):\#(p)":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:\#(local)"}}}}}"#.utf8)
    check(TailscaleSetup.serve(ours, dnsName: name) == .ours, "serve: our handler next to another app's 443 handler -> ours")
    check(TailscaleSetup.serve(Data(#"{"TCP":{\#(others)},"Web":{\#(otherWeb)}}"#.utf8), dnsName: name) == .off, "serve: only another app's handler -> off for us")
    check(TailscaleSetup.serve(Data("{}".utf8), dnsName: name) == .off && TailscaleSetup.serve(Data(), dnsName: name) == .off, "serve: empty config -> off")
    let taken = Data(#"{"TCP":{"\#(p)":{"HTTPS":true}},"Web":{"\#(name):\#(p)":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9999"}}}}}"#.utf8)
    if case .taken = TailscaleSetup.serve(taken, dnsName: name) { check(true, "serve: our port with another target -> taken (never overwritten)") }
    else { check(false, "serve: our port with another target -> taken (never overwritten)") }
    let extraPath = Data(#"{"TCP":{"\#(p)":{"HTTPS":true}},"Web":{"\#(name):\#(p)":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:\#(local)"},"/x":{"Path":"/tmp"}}}}}"#.utf8)
    if case .taken = TailscaleSetup.serve(extraPath, dnsName: name) { check(true, "serve: our port with an extra handler -> taken") }
    else { check(false, "serve: our port with an extra handler -> taken") }
    let funnel = Data(#"{"TCP":{"\#(p)":{"HTTPS":true}},"Web":{"\#(name):\#(p)":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:\#(local)"}}}},"AllowFunnel":{"\#(name):\#(p)":true}}"#.utf8)
    if case .taken(let why) = TailscaleSetup.serve(funnel, dnsName: name) { check(why.contains("Funnel"), "serve: Funnel on our port -> refused as public (\(why))") }
    else { check(false, "serve: Funnel on our port -> refused as public") }
    let tcp = Data(#"{"TCP":{"\#(p)":{"TCPForward":"127.0.0.1:22"}}}"#.utf8)
    if case .taken = TailscaleSetup.serve(tcp, dnsName: name) { check(true, "serve: a TCP forward on our port -> taken") }
    else { check(false, "serve: a TCP forward on our port -> taken") }

    // Fail closed: a shape we do not know is left alone, never read as "off" (Turn On would then overwrite it).
    func isTaken(_ json: String) -> Bool { if case .taken = TailscaleSetup.serve(Data(json.utf8), dnsName: name) { return true }; return false }
    let oursTCP = #""\#(p)":{"HTTPS":true}"#, oursWeb = #""\#(name):\#(p)":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:\#(local)"}}}"#
    check(isTaken(#"{"NewThing":{"a":1}}"#), "serve: an unknown top-level key -> taken (unknown config, left alone)")
    check(isTaken(#"{"TCP":{\#(oursTCP)},"Web":{\#(oursWeb)},"NewThing":true}"#), "serve: ours plus an unknown key -> taken")
    check(isTaken("[]") && isTaken("7") && isTaken(#"{"TCP":[]}"#) && isTaken(#"{"Web":{"x:1":7}}"#), "serve: wrong JSON shapes -> taken")
    check(isTaken(#"{"TCP":{"\#(p)":{"HTTPS":true,"NewFlag":1}},"Web":{\#(oursWeb)}}"#), "serve: an unknown flag on our port -> taken")
    check(isTaken(#"{"TCP":{\#(oursTCP)},"Web":{\#(oursWeb)}}"#.replacingOccurrences(of: #""Proxy""#, with: #""Proxy":"http://127.0.0.1:\#(local)","Extra""#)),
          "serve: an extra field in our handler -> taken")
    // Another host name on our port (any host counts): never ours, never turned off by us.
    check(isTaken(#"{"Web":{"other.example.ts.net:\#(p)":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:\#(local)"}}}}}"#), "serve: our port on another host name only -> taken")
    check(isTaken(#"{"TCP":{\#(oursTCP)},"Web":{\#(oursWeb),"other.example.ts.net:\#(p)":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:\#(local)"}}}}}"#),
          "serve: ours plus our port on another host name -> taken")
    check(isTaken(#"{"TCP":{\#(oursTCP)},"Web":{\#(oursWeb)},"AllowFunnel":{"other.example.ts.net:\#(p)":true}}"#), "serve: Funnel on our port for any host -> taken")
    // Services (Tailscale Services, newer CLIs) and Foreground (serve runs in a terminal): read, not skipped.
    check(TailscaleSetup.serve(Data(#"{"Services":{"svc:web":{"TCP":{"443":{"HTTPS":true}},"Web":{"web.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}}}"#.utf8), dnsName: name) == .off,
          "serve: a Service on another port -> off for us")
    check(isTaken(#"{"Services":{"svc:web":{"TCP":{"\#(p)":{"HTTPS":true}}}}}"#), "serve: a Service on our port -> taken")
    check(isTaken(#"{"Services":{"svc:web":{"Tun":true,"Odd":1}}}"#) || isTaken(#"{"Services":{"svc:web":7}}"#), "serve: a Service of unknown shape -> taken")
    check(isTaken(#"{"Foreground":{"s1":{"TCP":{"\#(p)":{"HTTPS":true}}}}}"#), "serve: a foreground serve on our port -> taken")
    check(TailscaleSetup.serve(Data(#"{"Foreground":{"s1":{"TCP":{"8443":{"HTTPS":true}}}}}"#.utf8), dnsName: name) == .off, "serve: a foreground serve on another port -> off for us")
    check(TailscaleSetup.serve(Data(#"{"TCP":{\#(oursTCP)},"Web":{\#(oursWeb.replacingOccurrences(of: name, with: name.uppercased()))}}"#.utf8), dnsName: name) == .ours,
          "serve: the host name matches in any case")

    // Pairing behind Serve: every peer is 127.0.0.1, so per-address counting would let any local process lock out
    // the phone. Shared source: wrong tries end the offer (after maxTriesPerSource) and say so; a new code is one click.
    let pp = HubPairing(devices: MemoryDeviceStore())
    pp.sharedSource = true
    let po = pp.offer()
    for _ in 0..<HubPairing.maxTriesPerSource { _ = pp.redeem("wrong words here", name: "x", source: "127.0.0.1") }
    check(pp.open == nil && pp.endedByWrongTries, "pairing behind serve: \(HubPairing.maxTriesPerSource) wrong codes end the offer, and it says why")
    check(pp.redeem(po.secret, name: "Phone", source: "127.0.0.1") == nil, "pairing behind serve: the ended offer no longer pairs")
    _ = pp.offer()
    check(!pp.endedByWrongTries && pp.open != nil, "pairing behind serve: a new code starts clean")
    let pd = HubPairing(devices: MemoryDeviceStore())
    let pdo = pd.offer()
    for _ in 0..<HubPairing.maxTriesPerSource { _ = pd.redeem("wrong words here", name: "x", source: "100.64.0.9") }
    check(pd.open != nil && !pd.endedByWrongTries && pd.redeem(pdo.secret, name: "Phone", source: "100.64.0.2") != nil,
          "pairing direct: one address's wrong codes do not end the offer for another address")

    // The commands: shown before they run; no Funnel, no reset; off names only our port.
    let cli = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    check(TailscaleSetup.onArguments == ["serve", "--bg", "--https=\(p)", "http://127.0.0.1:\(local)"], "serve: the on command (\(TailscaleSetup.onArguments))")
    check(TailscaleSetup.offArguments == ["serve", "--https=\(p)", "off"], "serve: the off command removes only our port")
    let shown = TailscaleSetup.command(cli: cli, TailscaleSetup.onArguments)
    check(shown == "'/Applications/Tailscale.app/Contents/MacOS/Tailscale' serve --bg --https=\(p) http://127.0.0.1:\(local)", "serve: the command as shown and copied (\(shown))")
    for a in [TailscaleSetup.onArguments, TailscaleSetup.offArguments] {
        check(!a.contains { $0.contains("funnel") || $0 == "reset" || $0 == "clear" }, "serve: never funnel, reset or clear (\(a))")
    }
    check(TailscaleSetup.origin(dnsName: name) == "https://mac.example.ts.net:\(p)", "serve: the page origin")

    // The hub behind Serve: loopback, no TLS, one allowed Origin.
    let b = FakeHubBackend(workspaces: [])
    let devices = MemoryDeviceStore()
    devices.add(token: "tok", device: HubDevice(id: "d1", name: "Phone", level: .read))
    let server = HubServer(backend: b, devices: devices, tickInterval: .milliseconds(200))
    server.allowedOrigin = TailscaleSetup.origin(dnsName: name)
    let port = try await server.start(host: "127.0.0.1", port: 0)
    let viaServe = "GET /ws HTTP/1.1\r\nHost: \(name):\(p)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-Forwarded-For: 100.64.0.2\r\n"
    func upgrade(_ head: String, _ frames: [Data] = []) async -> String {
        String(decoding: await rawExchange(port: port, [Data(head.utf8)] + frames), as: UTF8.self)
    }
    let hello = { (token: String) in clientFrame(1, Data(#"{"v":1,"type":"hello","id":"h","token":"\#(token)","client":"raw","clientVersion":"1"}"#.utf8)) }
    let good = await upgrade(viaServe + "Origin: https://\(name):\(p)\r\n\r\n", [hello("tok")])
    check(good.hasPrefix("HTTP/1.1 101") && good.contains("\"welcome\""), "serve hub: the ts.net page with its token is accepted")
    let noToken = await upgrade(viaServe + "Origin: https://\(name):\(p)\r\n\r\n", [hello("guess")])
    check(noToken.hasPrefix("HTTP/1.1 101") && noToken.contains("\"unauthorized\"") && !noToken.contains("\"welcome\""),
          "serve hub: from 127.0.0.1 with a wrong token -> unauthorized (loopback gives no trust)")
    let noHello = await upgrade(viaServe + "Origin: https://\(name):\(p)\r\n\r\n", [clientFrame(1, Data(#"{"v":1,"type":"watch","id":"s","pane":"w1:p1"}"#.utf8))])
    check(!noHello.contains("\"snapshot\"") && !noHello.contains("\"conversation\"") && noHello.contains("\"unauthorized\""), "serve hub: a request before hello -> unauthorized")
    for (o, what) in [("https://evil.example", "a foreign page"), ("https://\(name)", "the ts.net name on another port"),
                      ("http://\(name):\(p)", "plain http"), ("http://127.0.0.1:\(port)", "a local page"),
                      ("https://\(name):\(p).evil.example", "a look-alike"), ("null", "an opaque origin")] {
        check(await upgrade(viaServe + "Origin: \(o)\r\n\r\n").hasPrefix("HTTP/1.1 403"), "serve hub: \(what) is refused (403)")
    }
    check(await upgrade(viaServe + "\r\n").hasPrefix("HTTP/1.1 403"), "serve hub: no Origin is refused (403)")
    // DNS rebinding: a page whose Host and Origin agree, but are not the ts.net page.
    let rebind = "GET /ws HTTP/1.1\r\nHost: evil.example:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nOrigin: http://evil.example:\(port)\r\n\r\n"
    check(await upgrade(rebind).hasPrefix("HTTP/1.1 403"), "serve hub: a rebinding page (Host = Origin) is refused (403)")
    server.stop()

    // The bind rule is unchanged: Serve mode is plain loopback; never all addresses.
    check(HubBind.check(host: "0.0.0.0", tls: false, local: HubBind.local()) != nil, "serve hub: 0.0.0.0 still refused")
}
