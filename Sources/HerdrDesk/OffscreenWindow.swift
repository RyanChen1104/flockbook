import AppKit
import HerdrKit

/// The window of a check. AppKit moves a titled window back onto a screen when it is shown (`constrainFrameRect`) and
/// when SwiftUI or the toolbar resizes it, so a plain NSWindow at (-3000, -3000) appeared over what the owner was looking
/// at. This one never takes a frame on a screen: a frame that would touch one moves left of every screen, size kept.
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { Self.away(frameRect) }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) { super.setFrame(Self.away(frameRect), display: flag) }
    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
        super.setFrame(Self.away(frameRect), display: flag, animate: false)
    }
    override func setFrameOrigin(_ point: NSPoint) { super.setFrameOrigin(Self.away(NSRect(origin: point, size: frame.size)).origin) }
    override func setFrameTopLeftPoint(_ point: NSPoint) {
        super.setFrameOrigin(Self.away(NSRect(origin: NSPoint(x: point.x, y: point.y - frame.height), size: frame.size)).origin)
    }

    static func away(_ r: NSRect) -> NSRect { LaunchGuard.offscreen(r, screens: NSScreen.screens.map(\.frame)) }
}
