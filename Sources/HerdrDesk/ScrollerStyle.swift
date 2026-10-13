import AppKit

/// Scroll bars: thin overlay scrollers that fade at rest, also with a mouse attached.
/// With "Show scroll bars: Automatically" (the default), macOS gives every scroll view the legacy style (always shown,
/// with a wide track) while a mouse is connected. AppKit and SwiftUI scroll views take `NSScroller.preferredScrollerStyle`,
/// so the app answers `.overlay` there. An owner who chose "Always" in System Settings keeps it.
@MainActor
enum ScrollerStyle {
    private(set) static var installed = false

    static func install() {
        guard !installed else { return }
        let shown = CFPreferencesCopyAppValue("AppleShowScrollBars" as CFString, kCFPreferencesAnyApplication) as? String
        guard shown != "Always",
              let system = class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.preferredScrollerStyle)),
              let ours = class_getClassMethod(NSScroller.self, #selector(NSScroller.flockbookPreferredScrollerStyle)) else { return }
        method_exchangeImplementations(system, ours)
        installed = true
    }
}

extension NSScroller {
    @objc class func flockbookPreferredScrollerStyle() -> NSScroller.Style { .overlay }
}
