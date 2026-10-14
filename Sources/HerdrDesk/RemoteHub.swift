import CoreGraphics
import CryptoKit
import HerdrKit
import Foundation
import Observation
import os

let remoteLog = Logger(subsystem: "dev.mclee.flockbook", category: "remote")

/// Remote access (docs/design/remote-access.md): the hub server, the paired devices, the TLS identity and the
/// pairing offer. Off by default. Two modes:
/// - Tailscale (recommended): the hub listens on 127.0.0.1 only; Tailscale Serve ends HTTPS for the tailnet at
///   `https://<machine>.<tailnet>.ts.net:7480` with a real certificate (`TailscaleSetup`). The app runs `tailscale
///   serve` only when the owner clicks, and only for its own port.
/// - Direct (advanced, less safe): one address the owner picks (Tailscale or LAN) with a self-signed certificate.
/// Never all addresses.
@MainActor @Observable
final class RemoteHub {
    static let enabledKey = "remote.enabled", hostKey = "remote.host", portKey = "remote.port", modeKey = "remote.mode"
    /// Direct mode's port. Not 7480: Tailscale Serve may hold that one on the Tailscale address.
    static let defaultPort: UInt16 = 7482

    enum Mode: String, CaseIterable { case tailscale, direct }

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored let devices: HubDeviceStore
    /// Device file and certificate live here; nil = nothing on disk (snapshots).
    @ObservationIgnored let dir: URL?
    /// Phones' Web Push subscriptions: `push.json` in `dir` (in memory without one).
    @ObservationIgnored let pushes: MemoryPushStore
    /// The VAPID key (`vapid.key` in `dir`), loaded or made when the hub starts. Nil: no Web Push (no `dir`, or the
    /// file is broken; it is never replaced, since a new key would break every phone's subscription).
    @ObservationIgnored private(set) var vapid: P256.Signing.PrivateKey?
    /// Sends to the phones while the hub runs with a key; the trigger turns status changes into pushes.
    @ObservationIgnored private var pushCenter: PushCenter?
    @ObservationIgnored private var pushTrigger = PushTrigger()
    /// `flockbook-notify`'s door (127.0.0.1, token in `notify.json`), open while push is.
    @ObservationIgnored private var notifyDoor: NotifyEndpoint?
    /// The subscriptions, for Settings (refreshed by the poll and after each change here).
    private(set) var pushList: [PushSubscription] = []
    @ObservationIgnored private var server: HubServer?
    @ObservationIgnored private let pairing: HubPairing
    @ObservationIgnored private var poll: Task<Void, Never>?

    private(set) var running = false
    /// Why the hub is not running although it is on.
    private(set) var problem: String?
    private(set) var fingerprint: String?
    /// Tailscale mode: the CLI found, its status and our Serve handler, read when Settings shows (`checkTailscale`).
    private(set) var tailscaleCLI: String?
    private(set) var tailscale: TailscaleSetup.Status?
    private(set) var serve: TailscaleSetup.Serve?
    private(set) var checking = false
    /// `tailscale status` gave no readable answer (Tailscale not running, or the CLI misbehaved): its first error
    /// line. Shown as is, so a read failure never looks like "not signed in".
    private(set) var statusProblem: String?
    /// A Turn On / Turn Off is running.
    private(set) var switchingServe = false
    /// The last pairing code was stopped after wrong codes (the pairing sheet says so).
    private(set) var pairingEndedByWrongTries = false
    /// The last `tailscale serve` run's error output.
    private(set) var serveError: String?
    /// The name the running hub takes the page origin from.
    private var servedName: String?
    private(set) var port: UInt16?
    private(set) var connections = 0
    private(set) var offer: HubPairOffer?
    private(set) var deviceList: [HubDeviceRecord] = []
    private(set) var addresses: [HubAddress] = []
    private(set) var busy = false
    /// Settings > Remote access > Answer Claude questions from the phone.
    @ObservationIgnored private(set) var claudeHook: ClaudeHookSetup = .live

    init(model: AppModel?, devices: HubDeviceStore, dir: URL?) {
        self.model = model; self.devices = devices; self.dir = dir
        pushes = dir.map { FilePushStore(url: $0.appendingPathComponent("push.json")) } ?? MemoryPushStore()
        pushList = pushes.all
        pairing = HubPairing(devices: devices)
        deviceList = devices.all
        addresses = HubBind.local()
    }

    /// The app's hub: files in Application Support.
    static func live(model: AppModel) -> RemoteHub {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Flockbook/hub", isDirectory: true)
        return RemoteHub(model: model, devices: FileDeviceStore(url: dir.appendingPathComponent("devices.json")), dir: dir)
    }

    // MARK: Settings

    /// Snapshots: the on/off state shown, without the setting or a server.
    @ObservationIgnored private var previewEnabled: Bool?
    @ObservationIgnored private var previewMode: Mode?
    var enabled: Bool {
        get { access(keyPath: \.enabled); return previewEnabled ?? AppDefaults.store.bool(forKey: Self.enabledKey) }
        set {
            if previewEnabled != nil { withMutation(keyPath: \.enabled) { previewEnabled = newValue }; return }
            withMutation(keyPath: \.enabled) { AppDefaults.store.set(newValue, forKey: Self.enabledKey) }
            Task { newValue ? await start() : stop() }
        }
    }
    var mode: Mode {
        get { access(keyPath: \.mode); return previewMode ?? AppDefaults.store.string(forKey: Self.modeKey).flatMap(Mode.init) ?? .tailscale }
        set {
            if previewMode != nil { withMutation(keyPath: \.mode) { previewMode = newValue }; return }
            withMutation(keyPath: \.mode) { AppDefaults.store.set(newValue.rawValue, forKey: Self.modeKey) }
            if enabled, previewEnabled == nil { Task { await start() } }
        }
    }
    /// The chosen address (direct mode). Default: the first Tailscale address, else none (the owner picks).
    var host: String? {
        get {
            access(keyPath: \.host)
            return AppDefaults.store.string(forKey: Self.hostKey) ?? addresses.first { $0.kind == .tailscale }?.host
        }
        set {
            withMutation(keyPath: \.host) { AppDefaults.store.set(newValue, forKey: Self.hostKey) }
            if enabled, previewEnabled == nil { Task { await start() } }
        }
    }
    var portSetting: UInt16 {
        let p = AppDefaults.store.integer(forKey: Self.portKey)
        return p > 0 && p < 65536 ? UInt16(p) : Self.defaultPort
    }
    /// The page address (the PWA; its socket is `/ws` on the same origin), for the status line and the QR link.
    var url: String? {
        guard running else { return nil }
        if mode == .tailscale { return servedName.map(TailscaleSetup.origin(dnsName:)) }
        guard let host, let port else { return nil }
        return "https://\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }

    /// Tailscale mode is ready for a phone: signed in, HTTPS names on, our Serve handler on, hub running.
    var tailscaleReady: Bool { running && tailscale?.httpsReady == true && serve == .ours }


    func refreshAddresses() { if previewEnabled == nil { addresses = HubBind.local() } }

    // MARK: Server

    /// Starts (or restarts) the hub with the current settings. Errors land in `problem`.
    func start() async {
        stop()
        guard enabled, let model else { return }
        do {
            if vapid == nil, let dir { vapid = try? VAPIDKeyFile.loadOrCreate(at: dir.appendingPathComponent("vapid.key")) }
            let s = HubServer(backend: AppHubBackend(model: model, pushes: pushes, vapid: vapid), devices: devices, pairing: pairing)
            if mode == .tailscale {
                if tailscale == nil { await checkTailscale(restart: false) }
                guard let ts = tailscale, ts.signedIn, ts.httpsReady else {
                    problem = "Tailscale is not ready. Follow the steps below."; return
                }
                // Loopback, plain HTTP: Tailscale Serve brings HTTPS. Every request then comes from 127.0.0.1, so the
                // socket takes only the ts.net page's Origin, and the device token is needed as always.
                s.allowedOrigin = TailscaleSetup.origin(dnsName: ts.dnsName)
                // Every peer is 127.0.0.1 here: per-address counting would let a local process lock out the phone.
                pairing.sharedSource = true
                port = try await s.start(host: "127.0.0.1", port: UInt16(TailscaleSetup.localPort))
                servedName = ts.dnsName; fingerprint = nil
            } else {
                pairing.sharedSource = false
                refreshAddresses()
                guard let host else { problem = "Pick an address."; return }
                let id = try identity()
                port = try await s.start(host: host, port: portSetting, tls: id)
                fingerprint = id.fingerprint
            }
            server = s; running = true; problem = nil
            pushTrigger = PushTrigger()
            pushCenter = vapid.map { PushCenter(store: pushes, key: $0) }
            if pushCenter != nil, let dir {
                let door = NotifyEndpoint { [weak self] n in await self?.pushCenter?.notify(n, kind: .message) ?? 0 }
                do { _ = try await door.start(file: dir.appendingPathComponent("notify.json")); notifyDoor = door }
                catch { remoteLog.error("notify endpoint: \(error.localizedDescription, privacy: .public)") }
            }
            remoteLog.info("hub on \(self.mode.rawValue, privacy: .public) port \(self.port ?? 0)")
            poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, let s = self.server else { return }
                    self.connections = s.connectionCount
                    if let o = self.offer, self.pairing.open != o { self.offer = nil; self.pairingEndedByWrongTries = self.pairing.endedByWrongTries }
                    if self.deviceList != self.devices.all { self.deviceList = self.devices.all }
                    if self.pushList != self.pushes.all { self.pushList = self.pushes.all }
                    self.pushTick()
                }
            }
        } catch {
            problem = Self.describe(error)
            remoteLog.error("hub start failed: \(self.problem ?? "", privacy: .public)")
        }
    }

    func stop() {
        poll?.cancel(); poll = nil
        server?.stop(); server = nil; pushCenter = nil
        notifyDoor?.stop(); notifyDoor = nil
        running = false; port = nil; connections = 0; servedName = nil; fingerprint = nil
        cancelPairing()
    }

    // MARK: Web Push

    /// Settings: push when an agent is done (default on); push only while the owner is away from the Mac (default on).
    var pushDone: Bool {
        get { access(keyPath: \.pushDone); return AppDefaults.store.object(forKey: Self.pushDoneKey) as? Bool ?? true }
        set { withMutation(keyPath: \.pushDone) { AppDefaults.store.set(newValue, forKey: Self.pushDoneKey) } }
    }
    var pushOnlyAway: Bool {
        get { access(keyPath: \.pushOnlyAway); return AppDefaults.store.object(forKey: Self.pushAwayKey) as? Bool ?? true }
        set { withMutation(keyPath: \.pushOnlyAway) { AppDefaults.store.set(newValue, forKey: Self.pushAwayKey) } }
    }
    static let pushDoneKey = "remote.push.done", pushAwayKey = "remote.push.onlyAway"

    /// Every poll: status changes become pushes (needs you, done) when the policy allows; held pushes go out.
    private func pushTick() {
        guard let model else { return }
        let events = pushTrigger.update(model.store.workspaces)
        guard let c = pushCenter, !pushes.all.isEmpty else { return }
        let policy = PushPolicy(doneEnabled: pushDone, onlyWhenAway: pushOnlyAway)
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let due = events.filter { policy.allows($0.kind, idle: idle, locked: locked) }
        Task { @MainActor in
            for e in due { await c.notify(e.notice, kind: e.kind) }
            await c.flush()
        }
    }

    /// Settings > Send Test: what happened, in a line.
    func sendTestPush(device id: String) async -> String {
        guard let c = pushCenter else { return "Turn on remote access first." }
        let r = await c.test(device: id)
        pushList = pushes.all
        switch r {
        case .sent?: return "Sent. Check the phone."
        case .gone?: return "The phone turned notifications off. Turn them on again on the phone."
        case .failed(let status)?: return status == 0 ? "Could not reach the push service." : "The push service refused it (\(status))."
        case nil: return "This device has no notifications."
        }
    }

    func removePush(device id: String) { pushes.remove(device: id); pushList = pushes.all }

    /// `flockbook-notify` next to the app's executable (Contents/MacOS in the bundle, the build folder in development).
    /// Nil: not in this build. Snapshots show a fixed path.
    var notifyCommand: String? {
        if let previewNotifyCommand { return previewNotifyCommand }
        guard let exe = Bundle.main.executableURL else { return nil }
        let url = exe.deletingLastPathComponent().appendingPathComponent("flockbook-notify")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }
    @ObservationIgnored private var previewNotifyCommand: String?

    static func describe(_ e: Error) -> String {
        switch e as? HubServer.StartError {
        case .wildcard?: "Listening on all addresses is not allowed. Pick one address."
        case .notLocal(let h)?: "\(h) is not an address of this Mac now. Is Tailscale or the network on?"
        case .publicAddress(let h)?: "\(h) is a public address. Pick a Tailscale or local network address."
        case .needsTLS?: "This address needs TLS."
        case .failed(let why)?: "Could not listen: \(why)"
        case nil: "\(e)"
        }
    }

    /// Direct mode: the stored self-signed certificate, else a new one for this Mac's addresses. The browser checks
    /// the certificate itself; the fingerprint is for reference.
    private func identity() throws -> HubIdentity {
        guard let dir else { throw HubServer.StartError.failed("no certificate folder") }
        let tls = dir.appendingPathComponent("tls", isDirectory: true)
        if let id = try HubTLS.load(from: tls) { return id }
        // IP addresses only: the page address is always an IP. (The Mac's display name is often not ASCII, which made
        // Chrome refuse the certificate, and it carries the owner's name.)
        let names = ["127.0.0.1"] + addresses.map(\.host)
        return try HubTLS.selfSigned(in: tls, names: Array(Set(names)).sorted())
    }

    // MARK: Tailscale

    /// Reads Tailscale's state (read-only: `status --json`, `serve status --json`). Restarts the hub when the Mac's
    /// tailnet name changed or it was waiting for Tailscale.
    func checkTailscale(restart: Bool = true) async {
        guard previewEnabled == nil, !checking else { return }
        checking = true; defer { checking = false }
        tailscaleCLI = TailscaleSetup.findCLI()
        guard let cli = tailscaleCLI else { tailscale = nil; serve = nil; statusProblem = nil; return }
        if let r = await TailscaleSetup.run(cli: cli, ["status", "--json"]) {
            tailscale = TailscaleSetup.Status.parse(r.out)
            let first = r.err.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            statusProblem = tailscale == nil ? (first.isEmpty ? "no answer" : String(first.prefix(160))) : nil
            if tailscale == nil { remoteLog.error("tailscale status not readable: \(r.err, privacy: .public)") }
        } else { tailscale = nil; statusProblem = "could not run the Tailscale command" }
        if let ts = tailscale, !ts.dnsName.isEmpty, let r = await TailscaleSetup.run(cli: cli, ["serve", "status", "--json"]), r.status == 0 {
            serve = TailscaleSetup.serve(r.out, dnsName: ts.dnsName)
        } else { serve = nil }
        if restart, enabled, mode == .tailscale, tailscale?.httpsReady == true, servedName != tailscale?.dnsName { await start() }
    }

    /// The commands the owner may run, as shown and copied.
    var serveOnCommand: String { TailscaleSetup.command(cli: tailscaleCLI ?? "tailscale", TailscaleSetup.onArguments) }
    var serveOffCommand: String { TailscaleSetup.command(cli: tailscaleCLI ?? "tailscale", TailscaleSetup.offArguments) }

    /// Runs `tailscale serve` for our port only, after the owner clicked. Never when the port is someone else's.
    /// The Serve config is read again right before the command, and the command runs only for the state it was
    /// read in (on: port free; off: exactly our handler). Left: the moment between that read and the command;
    /// the CLI has no compare-and-set. Within it another program would have to change port 7480 itself.
    func setServe(on: Bool) async {
        guard previewEnabled == nil, !switchingServe, let cli = tailscaleCLI else { return }
        switchingServe = true; defer { switchingServe = false }
        await checkTailscale(restart: false)
        guard let dns = tailscale?.dnsName, !dns.isEmpty else { return }
        guard let read = await TailscaleSetup.run(cli: cli, ["serve", "status", "--json"]), read.status == 0 else {
            serveError = "Could not read the Serve settings. Nothing was changed."; return
        }
        serve = TailscaleSetup.serve(read.out, dnsName: dns)
        guard on ? serve == .off : serve == .ours else { return }
        let args = on ? TailscaleSetup.onArguments : TailscaleSetup.offArguments
        remoteLog.info("running tailscale \(args.joined(separator: " "), privacy: .public)")
        let r = await TailscaleSetup.run(cli: cli, args, timeout: 20)
        serveError = r == nil ? "Could not run Tailscale." : r!.status == 0 ? nil : r!.err.trimmingCharacters(in: .whitespacesAndNewlines)
        await checkTailscale()
    }

    // MARK: Pairing and devices

    @discardableResult
    func startPairing() -> HubPairOffer { let o = pairing.offer(); offer = o; pairingEndedByWrongTries = false; return o }
    func cancelPairing() { pairing.cancel(); offer = nil }
    /// Called while the pairing sheet is open: a used or expired offer is gone.
    func checkPairing() {
        if let o = offer, pairing.open != o { offer = nil; pairingEndedByWrongTries = pairing.endedByWrongTries }
        deviceList = devices.all
    }
    /// The QR code's link for the open offer.
    var pairLink: URL? {
        guard let offer, let url else { return nil }
        return URL(string: url).map { offer.link(base: $0, fingerprint: fingerprint) }
    }

    /// A changed level closes that device's connections at once; in-flight input is refused by the level check
    /// right before its keys.
    func setLevel(_ level: HubLevel, device id: String) { devices.setLevel(level, device: id); server?.dropRevoked(); deviceList = devices.all }
    /// Removes the device and closes its open connections at once.
    func revoke(device id: String) {
        devices.revoke(device: id); pushes.remove(device: id); pushList = pushes.all; server?.dropRevoked(); deviceList = devices.all
    }

    // MARK: Snapshots

    /// A hub that shows a state without listening (Settings snapshots).
    static func preview(running: Bool, devices: [(HubDevice, Date)], offer: Bool,
                        tailscale: TailscaleSetup.Status? = nil, serve: TailscaleSetup.Serve? = nil, mode: Mode = .direct,
                        pairStopped: Bool = false, claudeHook: ClaudeHookSetup.State = .off, pushes: [PushSubscription] = []) -> RemoteHub {
        let store = MemoryDeviceStore()
        for (i, d) in devices.enumerated() { store.add(token: "preview-\(i)", device: d.0, paired: d.1) }
        let hub = RemoteHub(model: nil, devices: store, dir: nil)
        hub.previewEnabled = running
        hub.addresses = [HubAddress(host: "127.0.0.1", kind: .loopback, interface: "lo0"),
                         HubAddress(host: "100.101.102.103", kind: .tailscale, interface: "utun4"),
                         HubAddress(host: "192.168.1.20", kind: .lan, interface: "en0")]
        hub.previewMode = mode
        hub.tailscaleCLI = TailscaleSetup.cliCandidates[0]
        hub.tailscale = tailscale; hub.serve = serve
        hub.running = running
        let direct = mode == .direct
        hub.port = running ? (direct ? defaultPort : UInt16(TailscaleSetup.localPort)) : nil
        hub.servedName = running && !direct ? tailscale?.dnsName : nil
        hub.connections = running ? 1 : 0
        hub.fingerprint = running && direct ? String(repeating: "3f9a", count: 16) : nil
        if offer { hub.startPairing() }
        hub.pairingEndedByWrongTries = pairStopped
        hub.claudeHook = .preview(claudeHook)
        hub.previewNotifyCommand = "/Applications/Flockbook.app/Contents/MacOS/flockbook-notify"
        for s in pushes { hub.pushes.add(s) }
        hub.pushList = hub.pushes.all
        return hub
    }
}
