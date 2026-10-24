import HerdrKit
import SwiftUI

extension AgentStatus {
    var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .blocked: "Needs you"
        case .done: "Done"
        case .unknown: "Unknown"
        }
    }
}

/// One shape + one color per state (DESIGN §6).
struct StatusGlyph: View {
    let status: AgentStatus
    var size: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch status {
        case .blocked:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(.green)
        case .working:
            SpinnerArc(reduceMotion: reduceMotion).frame(width: size - 2, height: size - 2).frame(width: size, height: size)
        case .idle, .unknown:
            Image(systemName: "circle")
                .font(.system(size: size - 1))
                .foregroundStyle(.tertiary)
        }
    }
}

/// The working glyph: a blue arc on a faint ring, turned by a Core Animation rotation. The render server runs it,
/// so the app does no per-frame work, and it stops by itself while the window is not drawn. Reduce Motion: static.
struct SpinnerArc: NSViewRepresentable {
    var reduceMotion = false
    func makeNSView(context: Context) -> ArcView { ArcView() }
    func updateNSView(_ v: ArcView, context: Context) { v.spinning = !reduceMotion }

    final class ArcView: NSView {
        private let ring = CAShapeLayer(), arc = CAShapeLayer()
        var spinning = true { didSet { if spinning != oldValue { updateAnimation() } } }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for l in [ring, arc] { l.fillColor = nil; l.lineWidth = 2; l.lineCap = .round; layer?.addSublayer(l) }
            arc.strokeEnd = 0.3
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            let r = bounds.insetBy(dx: 1, dy: 1)
            for l in [ring, arc] { l.frame = bounds; l.path = CGPath(ellipseIn: r, transform: nil) }
            arc.anchorPoint = CGPoint(x: 0.5, y: 0.5); arc.position = CGPoint(x: bounds.midX, y: bounds.midY)
            updateColors(); updateAnimation()
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateAnimation() }
        private func updateColors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ring.strokeColor = NSColor.labelColor.withAlphaComponent(0.15).cgColor
                arc.strokeColor = NSColor.systemBlue.cgColor
            }
        }
        private func updateAnimation() {
            guard spinning, window != nil else { arc.removeAnimation(forKey: "spin"); return }
            guard arc.animation(forKey: "spin") == nil else { return }
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0; a.toValue = -2 * Double.pi   // clockwise on screen (layer y is up)
            a.duration = 1; a.repeatCount = .infinity; a.isRemovedOnCompletion = false
            arc.add(a, forKey: "spin")
        }
    }
}

struct BlockedBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.semibold)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 18)
            .background(Color.orange, in: Capsule())
    }
}

struct Monogram: View {
    let text: String
    var inverted = false
    var body: some View {
        let letters = Monogram.letters(text)
        Text(letters)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(inverted ? Color(nsColor: .windowBackgroundColor) : Color.primary.opacity(0.7))
            .frame(width: 22, height: 22)
            .background(inverted ? Color.primary.opacity(0.8) : Color.primary.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: Radius.control))
    }
    /// Name without a leading "[TAG] ". Falls back to the raw name when nothing remains.
    static func displayName(_ raw: String) -> String {
        guard raw.hasPrefix("["), let e = raw.firstIndex(of: "]") else { return raw }
        let rest = String(raw[raw.index(after: e)...]).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? raw : rest
    }
    static func letters(_ raw: String) -> String { WorkspaceMonogram.letters(raw) }
}

extension Tab {
    var isSplit: Bool { panes.count > 1 }
    var primaryAgent: Agent? { panes.compactMap(\.agent).first }
}

extension Workspace {
    var blockedCount: Int { tabs.filter { $0.status == .blocked }.count }
    var workingCount: Int { tabs.filter { $0.status == .working }.count }
}

func role(for agentName: String) -> (symbol: String, name: String) {
    switch agentName.split(separator: "-").last.map(String.init) ?? "" {
    case "orch": ("sparkles", "Orchestrator")
    case "dev": ("chevron.left.forwardslash.chevron.right", "Developer")
    case "rev": ("eye", "Reviewer")
    case "res": ("book", "Researcher")
    case "des": ("pencil.and.outline", "Designer")
    default: ("person.crop.circle", "Agent")
    }
}
