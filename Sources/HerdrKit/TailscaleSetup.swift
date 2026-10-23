import Foundation

/// Remote access through Tailscale Serve: the hub listens on 127.0.0.1 (`localPort`, plain HTTP) and Tailscale ends
/// HTTPS for the tailnet at `https://<machine>.<tailnet>.ts.net:<servePort>` with its own renewed certificate.
/// Our own HTTPS port, so the page is its own origin and another app's Serve config (often on 443) stays as it is.
///
/// Read-only here: `tailscale status --json` and `tailscale serve status --json` are parsed. The app runs
/// `onArguments` / `offArguments` only when the owner clicks, and shows them first. Never Funnel, never reset.
public enum TailscaleSetup {
    /// The HTTPS port on the tailnet.
    public static let servePort = 7480
    /// The hub's port on 127.0.0.1.
    public static let localPort = 7481

    /// Where the CLI may be: the Mac app's own binary first (it works with the App Store and standalone apps), then PATH ones.
    public static let cliCandidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]

    public static func findCLI(exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        cliCandidates.first(where: exists)
    }

    public static let onArguments = ["serve", "--bg", "--https=\(servePort)", "http://127.0.0.1:\(localPort)"]
    /// Removes only our port's handler.
    public static let offArguments = ["serve", "--https=\(servePort)", "off"]

    /// The command as shown and copied (the CLI path quoted for a shell).
    public static func command(cli: String, _ args: [String]) -> String {
        ([ShellQuote.quoted(cli)] + args).joined(separator: " ")
    }

    /// The page's origin: the only one whose socket the hub takes in this mode.
    public static func origin(dnsName: String) -> String { "https://\(dnsName):\(servePort)" }

    public struct Peer: Sendable, Hashable {
        public var name: String, os: String, online: Bool
        public init(name: String, os: String, online: Bool) { self.name = name; self.os = os; self.online = online }
    }

    public struct Status: Sendable, Hashable {
        /// BackendState "Running": on and signed in.
        public var signedIn: Bool
        public var backendState: String
        /// This Mac's MagicDNS name without the last dot; empty when there is none.
        public var dnsName: String
        public var magicDNS: Bool
        /// The tailnet gives this Mac an HTTPS certificate (CertDomains holds its name).
        public var certificates: Bool
        public var peers: [Peer]

        public init(signedIn: Bool, backendState: String, dnsName: String, magicDNS: Bool, certificates: Bool, peers: [Peer]) {
            self.signedIn = signedIn; self.backendState = backendState; self.dnsName = dnsName
            self.magicDNS = magicDNS; self.certificates = certificates; self.peers = peers
        }

        public var httpsReady: Bool { magicDNS && certificates && !dnsName.isEmpty }
        /// Phones and tablets, by name.
        public var phones: [Peer] {
            peers.filter { ["android", "ios", "ipados"].contains($0.os.lowercased()) }.sorted { $0.name < $1.name }
        }

        /// `tailscale status --json`. Nil: not that JSON.
        public static func parse(_ data: Data) -> Status? {
            guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            let state = j["BackendState"] as? String ?? ""
            let me = j["Self"] as? [String: Any] ?? [:]
            var dns = me["DNSName"] as? String ?? ""
            if dns.hasSuffix(".") { dns.removeLast() }
            let tailnet = j["CurrentTailnet"] as? [String: Any] ?? [:]
            let magic = tailnet["MagicDNSEnabled"] as? Bool ?? false
            let certs = (j["CertDomains"] as? [String] ?? []).map { $0.lowercased() }
            let peers = (j["Peer"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }.map { p in
                Peer(name: p["HostName"] as? String ?? "", os: p["OS"] as? String ?? "", online: p["Online"] as? Bool ?? false)
            }.sorted { $0.name < $1.name }
            return Status(signedIn: state == "Running", backendState: state, dnsName: dns, magicDNS: magic,
                          certificates: !dns.isEmpty && certs.contains(dns.lowercased()), peers: peers)
        }
    }

    public enum Serve: Sendable, Hashable {
        /// Nothing on our port.
        case off
        /// Our port serves exactly our hub, tailnet only.
        case ours
        /// Something else uses our port; never overwritten.
        case taken(String)
    }

    /// `tailscale serve status --json` (empty output: no config) for our port on `dnsName`. Fails closed: a key or
    /// shape not known here is `.taken`, never `.off`, so Turn On cannot overwrite a config this code cannot read.
    /// Ours: exactly `TCP[7480] = {HTTPS: true}` and one `Web` entry on port 7480, for our host, with one handler
    /// `/` -> our proxy; nothing else on port 7480 for any host (Funnel, Services, Foreground included).
    public static func serve(_ data: Data, dnsName: String) -> Serve {
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .off }
        guard let j = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] else {
            return .taken("Serve config not readable")
        }
        let port = String(servePort)
        let unknown = "Serve has settings Flockbook does not know"
        var tcp: [String: Any] = [:], web: [String: Any] = [:], funnel: [String: Any] = [:]
        for (key, value) in j where !(value is NSNull) {
            switch key {
            case "TCP": guard let v = value as? [String: Any] else { return .taken(unknown) }; tcp = v
            case "Web": guard let v = value as? [String: Any] else { return .taken(unknown) }; web = v
            case "AllowFunnel": guard let v = value as? [String: Any] else { return .taken(unknown) }; funnel = v
            case "Services", "Foreground":
                // Other configs of the same shape: they may sit next to ours, never on our port.
                guard let v = value as? [String: Any] else { return .taken(unknown) }
                for sub in v.values {
                    guard let c = sub as? [String: Any] else { return .taken(unknown) }
                    switch usesPort(c, port: port, extraKeys: key == "Services" ? ["Tun"] : []) {
                    case nil: return .taken(unknown)
                    case true?: return .taken(key == "Services" ? "A Tailscale Service uses port \(port)" : "A serve running in a terminal uses port \(port)")
                    case false?: break
                    }
                }
            default: return .taken(unknown)
            }
        }
        guard tcp.values.allSatisfy({ $0 is [String: Any] }), web.values.allSatisfy({ $0 is [String: Any] }) else { return .taken(unknown) }
        let webOnPort = web.filter { hostPort($0.key, port) }
        if funnel.contains(where: { hostPort($0.key, port) && !($0.value is NSNull) && ($0.value as? Bool) != false }) {
            return .taken("Funnel (public internet) is on for port \(port)")
        }
        let tcpOurs = tcp[port] as? [String: Any]
        if tcpOurs == nil && webOnPort.isEmpty { return .off }
        guard let tcpOurs, tcpOurs.count == 1, tcpOurs["HTTPS"] as? Bool == true else { return .taken("Port \(port) is used by another Serve setting") }
        guard webOnPort.count == 1, let (host, entry) = webOnPort.first.map({ ($0.key, $0.value) }),
              host.lowercased() == "\(dnsName):\(port)".lowercased(),
              let e = entry as? [String: Any], e.count == 1,
              let handlers = e["Handlers"] as? [String: Any], handlers.count == 1,
              let root = handlers["/"] as? [String: Any], root.count == 1,
              root["Proxy"] as? String == "http://127.0.0.1:\(localPort)" else { return .taken("Port \(port) serves something else") }
        return .ours
    }

    /// `host:port` names `port`.
    private static func hostPort(_ key: String, _ port: String) -> Bool { key.hasSuffix(":" + port) }

    /// Whether a nested serve config uses `port`. Nil: a shape not known here.
    private static func usesPort(_ c: [String: Any], port: String, extraKeys: Set<String>) -> Bool? {
        var uses = false
        for (key, value) in c where !(value is NSNull) {
            switch key {
            case "TCP": guard let v = value as? [String: Any] else { return nil }; uses = uses || v[port] != nil
            case "Web", "AllowFunnel": guard let v = value as? [String: Any] else { return nil }; uses = uses || v.keys.contains { hostPort($0, port) }
            default: if !extraKeys.contains(key) { return nil }
            }
        }
        return uses
    }

    /// The CLI's environment: `base` plus TAILSCALE_BE_CLI=1. Without a terminal (an app opened from Finder has no
    /// TERM), the Mac app's binary otherwise starts its GUI and fails ("The Tailscale GUI failed to start").
    public static func cliEnvironment(_ base: [String: String]) -> [String: String] {
        var env = base
        env["TAILSCALE_BE_CLI"] = "1"
        return env
    }

    /// Runs the CLI with a time limit. Off the main thread.
    public static func run(cli: String, _ args: [String], timeout: Double = 8,
                           base: [String: String] = ProcessInfo.processInfo.environment) async -> (status: Int32, out: Data, err: String)? {
        await withCheckedContinuation { (k: CheckedContinuation<(status: Int32, out: Data, err: String)?, Never>) in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: cli)
                p.arguments = args
                p.environment = cliEnvironment(base)
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { k.resume(returning: nil); return }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                // Read both pipes before waiting, so a full pipe cannot stall the process.
                var o = Data(), e = Data()
                let g = DispatchGroup()
                g.enter(); DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                g.enter(); DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                g.wait()
                p.waitUntilExit()
                timer.cancel()
                k.resume(returning: (p.terminationStatus, o, String(decoding: e, as: UTF8.self)))
            }
        }
    }
}
