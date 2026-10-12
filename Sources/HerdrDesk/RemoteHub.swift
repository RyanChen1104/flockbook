import HerdrKit
import Foundation
import Observation
import os

let remoteLog = Logger(subsystem: "dev.mclee.flockbook", category: "remote")

/// Remote access (docs/design/remote-access.md): the hub server, the paired devices, the TLS identity and the
/// pairing offer. Off by default. It listens on one address the owner picks (Tailscale or LAN, TLS), never on all.
@MainActor @Observable
final class RemoteHub {
    static let enabledKey = "remote.enabled", hostKey = "remote.host", portKey = "remote.port"
    static let defaultPort: UInt16 = 7480

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored let devices: HubDeviceStore
    /// Device file and certificate live here; nil = nothing on disk (snapshots).
    @ObservationIgnored let dir: URL?
    @ObservationIgnored private var server: HubServer?
    @ObservationIgnored private let pairing: HubPairing
    @ObservationIgnored private var poll: Task<Void, Never>?

    private(set) var running = false
    /// Why the hub is not running although it is on.
    private(set) var problem: String?
    private(set) var fingerprint: String?
    /// The `*.ts.net` name of a `tailscale cert` certificate in use; the page address uses it.
    private(set) var tailnetName: String?
    private(set) var port: UInt16?
    private(set) var connections = 0
    private(set) var offer: HubPairOffer?
    private(set) var deviceList: [HubDeviceRecord] = []
    private(set) var addresses: [HubAddress] = []
    private(set) var busy = false

    init(model: AppModel?, devices: HubDeviceStore, dir: URL?) {
        self.model = model; self.devices = devices; self.dir = dir
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
    var enabled: Bool {
        get { access(keyPath: \.enabled); return previewEnabled ?? AppDefaults.store.bool(forKey: Self.enabledKey) }
        set {
            if previewEnabled != nil { withMutation(keyPath: \.enabled) { previewEnabled = newValue }; return }
            withMutation(keyPath: \.enabled) { AppDefaults.store.set(newValue, forKey: Self.enabledKey) }
            Task { newValue ? await start() : stop() }
        }
    }
    /// The chosen address. Default: the first Tailscale address, else none (the owner picks).
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
        guard running, let host, let port else { return nil }
        let name = tailnetName ?? (host.contains(":") ? "[\(host)]" : host)
        return "https://\(name):\(port)"
    }

    func refreshAddresses() { if previewEnabled == nil { addresses = HubBind.local() } }

    // MARK: Server

    /// Starts (or restarts) the hub with the current settings. Errors land in `problem`.
    func start() async {
        stop()
        guard enabled, let model else { return }
        refreshAddresses()
        guard let host else { problem = "Pick an address."; return }
        do {
            let id = try identity()
            let s = HubServer(backend: AppHubBackend(model: model), devices: devices, pairing: pairing)
            port = try await s.start(host: host, port: portSetting, tls: id)
            server = s; running = true; problem = nil; fingerprint = id.fingerprint; tailnetName = id.tailnetName
            remoteLog.info("hub on \(host, privacy: .public):\(self.port ?? 0)")
            poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, let s = self.server else { return }
                    self.connections = s.connectionCount
                    if let o = self.offer, self.pairing.open != o { self.offer = nil }
                    if self.deviceList != self.devices.all { self.deviceList = self.devices.all }
                }
            }
        } catch {
            problem = Self.describe(error)
            remoteLog.error("hub start failed: \(self.problem ?? "", privacy: .public)")
        }
    }

    func stop() {
        poll?.cancel(); poll = nil
        server?.stop(); server = nil
        running = false; port = nil; connections = 0; tailnetName = nil
        cancelPairing()
    }

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

    /// On a Tailscale address: the `tailscale cert` pair when the owner put one in `<hub>/tailscale/` (cert.pem,
    /// key.pem; the app never runs `tailscale cert` itself). Else the stored self-signed certificate, else a new one
    /// for this Mac's addresses. The browser checks the certificate itself; the fingerprint is for reference.
    private func identity() throws -> HubIdentity {
        guard let dir else { throw HubServer.StartError.failed("no certificate folder") }
        let ts = dir.appendingPathComponent("tailscale", isDirectory: true)
        let tsCert = ts.appendingPathComponent("cert.pem"), tsKey = ts.appendingPathComponent("key.pem")
        if let host, HubBind.kind(host) == .tailscale, FileManager.default.fileExists(atPath: tsCert.path), FileManager.default.fileExists(atPath: tsKey.path) {
            do { return try HubTLS.fromPEM(cert: tsCert, key: tsKey, into: ts.appendingPathComponent("bundle")) }
            catch { remoteLog.error("tailscale cert not usable, using the self-signed one: \(String(describing: error), privacy: .public)") }
        }
        let tls = dir.appendingPathComponent("tls", isDirectory: true)
        if let id = try HubTLS.load(from: tls) { return id }
        // IP addresses only: the page address is always an IP. (The Mac's display name is often not ASCII, which made
        // Chrome refuse the certificate, and it carries the owner's name.)
        let names = ["127.0.0.1"] + addresses.map(\.host)
        return try HubTLS.selfSigned(in: tls, names: Array(Set(names)).sorted())
    }

    // MARK: Pairing and devices

    @discardableResult
    func startPairing() -> HubPairOffer { let o = pairing.offer(); offer = o; return o }
    func cancelPairing() { pairing.cancel(); offer = nil }
    /// Called while the pairing sheet is open: a used or expired offer is gone.
    func checkPairing() {
        if let o = offer, pairing.open != o { offer = nil }
        deviceList = devices.all
    }
    /// The QR code's link for the open offer.
    var pairLink: URL? {
        guard let offer, let url else { return nil }
        return URL(string: url).map { offer.link(base: $0, fingerprint: fingerprint) }
    }

    func setLevel(_ level: HubLevel, device id: String) { devices.setLevel(level, device: id); deviceList = devices.all }
    /// Removes the device and closes its open connections at once.
    func revoke(device id: String) { devices.revoke(device: id); server?.dropRevoked(); deviceList = devices.all }

    // MARK: Snapshots

    /// A hub that shows a state without listening (Settings snapshots).
    static func preview(running: Bool, devices: [(HubDevice, Date)], offer: Bool) -> RemoteHub {
        let store = MemoryDeviceStore()
        for (i, d) in devices.enumerated() { store.add(token: "preview-\(i)", device: d.0, paired: d.1) }
        let hub = RemoteHub(model: nil, devices: store, dir: nil)
        hub.previewEnabled = running
        hub.addresses = [HubAddress(host: "127.0.0.1", kind: .loopback, interface: "lo0"),
                         HubAddress(host: "100.101.102.103", kind: .tailscale, interface: "utun4"),
                         HubAddress(host: "192.168.1.20", kind: .lan, interface: "en0")]
        hub.running = running
        hub.port = running ? defaultPort : nil
        hub.connections = running ? 1 : 0
        hub.fingerprint = running ? String(repeating: "3f9a", count: 16) : nil
        if offer { hub.startPairing() }
        return hub
    }
}
