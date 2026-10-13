import AppKit

/// Scroll bars: thin overlay scrollers that fade at rest, also with a mouse attached.
/// With "Show scroll bars: Automatically" (the default), macOS gives every scroll view the legacy style (always shown,
/// with a wide track) while a mouse is connected. AppKit and SwiftUI scroll views take `NSScroller.preferredScrollerStyle`
/// (again on each change of the setting), so the app answers there: legacy only when the owner chose "Always".
@MainActor
enum ScrollerStyle {
    private(set) static var installed = false

    static func install() {
        guard !installed,
              let system = class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.preferredScrollerStyle)),
              let ours = class_getClassMethod(NSScroller.self, #selector(NSScroller.flockbookPreferredScrollerStyle)) else { return }
        method_exchangeImplementations(system, ours)
        installed = true
        // A mouse plugged in or the setting changed: AppKit then sets the system's style on every existing scroll view
        // without asking the getter above. Set ours again after it.
        NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { applyToOpenWindows() } }
        }
        // With a mouse attached, Always <-> Automatically keeps the system's style (legacy), so no notice above: listen to
        // the setting itself too.
        DistributedNotificationCenter.default().addObserver(forName: .init("AppleShowScrollBarsSettingChanged"), object: nil, queue: .main) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { applyToOpenWindows() } }
        }
    }

    static func applyToOpenWindows() {
        let want = style(showScrollBars: showScrollBars)
        func visit(_ v: NSView) {
            if let sv = v as? NSScrollView, sv.scrollerStyle != want { sv.scrollerStyle = want }
            v.subviews.forEach(visit)
        }
        for w in NSApp.windows { (w.contentView?.superview ?? w.contentView).map(visit) }
    }

    /// The style for a value of the global AppleShowScrollBars ("Always", "WhenScrolling", "Automatic" or unset).
    nonisolated static func style(showScrollBars: String?) -> NSScroller.Style { showScrollBars == "Always" ? .legacy : .overlay }

    /// The current global setting, read each time: System Settings can change it while the app runs.
    nonisolated static var showScrollBars: String? {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleShowScrollBars"] as? String
    }
}

extension NSScroller {
    @objc class func flockbookPreferredScrollerStyle() -> NSScroller.Style { ScrollerStyle.style(showScrollBars: ScrollerStyle.showScrollBars) }
}
