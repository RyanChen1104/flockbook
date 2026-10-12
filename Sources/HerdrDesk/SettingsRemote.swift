import HerdrKit
import SwiftUI
import CoreImage.CIFilterBuiltins

/// Settings > Remote access: off by default; one address; the state always in sight; pairing and the device list in sheets.
struct RemoteAccessSection: View {
    @Bindable var hub: RemoteHub
    @State private var pairing = false
    @State private var showDevices = false

    var body: some View {
        Section {
            Toggle(isOn: $hub.enabled) {
                Text("Remote access")
                Text(status).foregroundStyle(hub.problem != nil && hub.enabled ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            if hub.enabled {
                Picker(selection: Binding(get: { hub.host ?? "" }, set: { hub.host = $0 })) {
                    if hub.host == nil || !hub.addresses.contains(where: { $0.host == hub.host }) {
                        Text(hub.host.map { "\($0) (not on this Mac now)" } ?? "Choose…").tag(hub.host ?? "")
                    }
                    ForEach(hub.addresses, id: \.host) { a in Text(Self.label(a)).tag(a.host) }
                } label: {
                    Text("Address")
                    Text(Self.addressNote(hub.host.flatMap(HubBind.kind)))
                        .foregroundStyle(HubBind.kind(hub.host ?? "") == .lan ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                LabeledContent {
                    HStack {
                        Button("Devices…") { showDevices = true }
                        Button("Pair a Device…") { hub.startPairing(); pairing = true }.disabled(!hub.running)
                    }
                } label: {
                    Text("Devices")
                    Text(hub.deviceList.isEmpty ? "None paired." : "\(hub.deviceList.count) paired, \(hub.deviceList.filter { $0.device.level == .input }.count) with input.")
                }
            }
        } header: {
            Text("Remote access")
        } footer: {
            Label {
                Text(hub.enabled ? "Paired devices can read your agents' conversations. Input is off for each device until you turn it on."
                                 : "Use Flockbook from your phone over Tailscale or your local network.")
            } icon: {
                Image(systemName: hub.running ? "antenna.radiowaves.left.and.right" : "lock.fill")
                    .foregroundStyle(hub.running ? .orange : .secondary)
            }
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $pairing, onDismiss: { hub.cancelPairing() }) { PairSheet(hub: hub) }
        .sheet(isPresented: $showDevices) { DevicesSheet(hub: hub) }
        .onAppear { hub.refreshAddresses() }
    }

    private var status: String {
        guard hub.enabled else { return "Off. Nothing listens." }
        if let p = hub.problem { return p }
        guard let url = hub.url else { return "Starting…" }
        let c = hub.connections
        return "On at \(url)" + (c > 0 ? " · \(c) connected" : "")
    }

    /// Under the address picker. A LAN address gets the honest warning: the phone's browser cannot pin the
    /// self-signed certificate, so a fake certificate on the same Wi-Fi could take the pairing.
    static func addressNote(_ kind: HubBind.Kind?) -> String {
        switch kind {
        case .lan?: "Less safe: anyone on this Wi-Fi who can fake the certificate could pair. Use Tailscale when you can."
        case .tailscale?: "Only this address listens. Tailscale checks every device, so this is the safe choice."
        default: "Only this address listens. Tailscale is recommended."
        }
    }

    static func label(_ a: HubAddress) -> String {
        switch a.kind {
        case .tailscale?: "Tailscale · \(a.host)"
        case .lan?: "Local network (\(a.interface)) · \(a.host) (less safe)"
        case .loopback?: "This Mac only · \(a.host)"
        case nil: a.host
        }
    }
}

/// The QR code and the 6 words, with the time left. Closes itself when a device paired.
struct PairSheet: View {
    let hub: RemoteHub
    @Environment(\.dismiss) private var dismiss
    @State private var startCount: Int?

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair a Device").font(.title3.weight(.semibold))
            if let offer = hub.offer {
                if let link = hub.pairLink, let qr = Self.qr(link.absoluteString) {
                    // Drawn at its own size (whole points per module, nearest-neighbour pixels): never scaled again.
                    Image(nsImage: qr).interpolation(.none)
                        .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Pairing QR code")
                }
                Text("Scan with the phone's camera, or type these words on the device:").font(.callout).foregroundStyle(.secondary)
                Text(offer.code).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(offer.expires.timeIntervalSince(ctx.date)))
                    Text(left > 0 ? "Valid for \(left / 60):\(String(format: "%02d", left % 60)). Works once." : "Expired.")
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        .onChange(of: ctx.date) { _, _ in hub.checkPairing() }
                }
                if let fp = hub.fingerprint {
                    Text("Certificate \(fp.prefix(16))… For reference only: the phone's browser checks the certificate, not this code.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
            } else if let start = startCount, hub.deviceList.count > start {
                Label("Paired \(hub.deviceList.last?.device.name ?? "")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("It can read. Turn on input in Devices if you want it to type, allow or answer.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("The code expired or was used.").foregroundStyle(.secondary)
                Button("New Code") { hub.startPairing() }
            }
            HStack { Spacer(); Button(hub.offer == nil ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { startCount = hub.deviceList.count }
    }

    /// The QR code at about `side` points: a whole number of points per module, and pixels made with
    /// nearest-neighbour sampling at 2 per point (sharp on Retina and on 1x displays). Black on white, nothing grey.
    static func qr(_ text: String, side: CGFloat = 200) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let modules = out.extent.width
        let points = max(1, (side / modules).rounded(.down))
        let scaled = out.samplingNearest().transformed(by: CGAffineTransform(scaleX: points * 2, y: points * 2))
        guard let cg = CIContext(options: [.workingColorSpace: NSNull()]).createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: modules * points, height: modules * points))
    }
}

/// Paired devices: level per device, and remove.
struct DevicesSheet: View {
    let hub: RemoteHub
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paired Devices").font(.title3.weight(.semibold))
            if hub.deviceList.isEmpty {
                Text("No devices yet. Use Pair a Device.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Form {
                    ForEach(hub.deviceList, id: \.device.id) { r in
                        LabeledContent {
                            HStack {
                                Picker("Level", selection: Binding(get: { r.device.level }, set: { hub.setLevel($0, device: r.device.id) })) {
                                    Text("Read").tag(HubLevel.read)
                                    Text("Input").tag(HubLevel.input)
                                }
                                .pickerStyle(.segmented).labelsHidden().fixedSize()
                                Button(role: .destructive) { hub.revoke(device: r.device.id) } label: { Text("Remove") }
                            }
                        } label: {
                            Text(r.device.name)
                            Text("Paired \(r.paired.formatted(date: .abbreviated, time: .omitted))")
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text("Input lets a device type to agents, allow or deny, and answer questions. Removing a device closes its connection.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 460)
    }
}
