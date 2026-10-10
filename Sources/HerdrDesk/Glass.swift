import SwiftUI
import AppKit

private struct FlatGlassKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Snapshot mode: off-screen rendering cannot draw .glassEffect, so use a plain fill.
    var flatGlass: Bool { get { self[FlatGlassKey.self] } set { self[FlatGlassKey.self] = newValue } }
}

struct GlassCard: ViewModifier {
    @Environment(\.flatGlass) private var flat
    let radius: CGFloat
    var tint: Color?
    func body(content: Content) -> some View {
        if flat {
            content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color.primary.opacity(0.1)))
        } else if let tint {
            content.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: radius))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius))
        }
    }
}
extension View {
    func glassCard(radius: CGFloat, tint: Color? = nil) -> some View { modifier(GlassCard(radius: radius, tint: tint)) }
}

/// User setting: how see-through the window is. Off = opaque (previous look).
enum WindowGlass: String, CaseIterable, Identifiable {
    case off, subtle, full
    var id: String { rawValue }
    static let key = "windowGlass"
    /// Named by the result: "Off" for transparency read as a double negative.
    var label: String { switch self { case .off: "Opaque"; case .subtle: "Subtle"; case .full: "Glass" } }

    /// Behind-window blur under the whole window. Off: none (the surface is opaque).
    var material: NSVisualEffectView.Material? { self == .off ? nil : .underWindowBackground }
    /// Opacity of the content colour over that blur. Text needs the surface almost opaque (reading.md §13).
    var tint: Double {
        switch self {
        case .off: 1
        case .subtle: 0.88
        case .full: 0.75
        }
    }
    /// Cards and the selected tab.
    var card: AnyShapeStyle {
        switch self {
        case .off: AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        case .subtle: AnyShapeStyle(.thickMaterial)
        case .full: AnyShapeStyle(.regularMaterial)
        }
    }
}

/// Reads the effective glass mode inside a view.
struct GlassReader<V: View>: View {
    @AppStorage(WindowGlass.key, store: AppDefaults.store) private var raw = WindowGlass.full.rawValue
    @Environment(\.accessibilityReduceTransparency) private var reduce
    @Environment(\.flatGlass) private var flat
    @ViewBuilder let content: (WindowGlass) -> V
    var body: some View { content(reduce || flat ? .off : (WindowGlass(rawValue: raw) ?? .full)) }
}

/// The one surface of the window: behind-window blur + the content colour at `tint`. The window draws it behind everything,
/// and the sidebar column draws the same view inside the system sidebar panel, so both show the same pixels (a behind-window
/// blur samples the desktop, not the layers in between).
struct WindowSurface: View {
    let glass: WindowGlass
    var body: some View {
        ZStack {
            if let m = glass.material { BehindWindowBlur(material: m) }
            Color(nsColor: .textBackgroundColor).opacity(glass.tint)
        }
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}
