import AppKit
import HerdrKit
import SwiftUI

/// Offscreen check for the permission card in the composer slot (`--test-permission`). Nothing is sent to herdr: the card
/// is read from a synthetic screen and shown on the preview store's blocked tab; no button is pressed.
extension ContentTests {
    /// Claude Code's prompt for a long heredoc as a 40-line pane read shows it: the box's top rule and header have scrolled
    /// off, so the whole visible screen becomes the card's command.
    static func longPromptScreen() -> String {
        let lines = (21...60).map { "│ line \($0): lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore \($0)" }
        return (lines + ["│ EOF", "│ wc -l report.txt", String(repeating: "╌", count: 118),
                         "Heredoc with unquoted delimiter undergoes shell expansion", "", "Do you want to proceed?",
                         "❯ 1. Yes", "  2. Yes, and switch to auto mode · auto mode handles these prompts for you", "  3. No", "",
                         "Esc to cancel · Tab to amend"]).joined(separator: "\n")
    }
    /// A whole box whose command is one word with no break point.
    static func widePromptScreen() -> String {
        ([String(repeating: "─", count: 118), " Bash command", "", String(repeating: "╌", count: 118),
          "   echo " + String(repeating: "x", count: 1500), String(repeating: "╌", count: 118), "   Print a very long word", "",
          " Do you want to proceed?", " ❯ 1. Yes", "   2. No", "", " Esc to cancel · Tab to amend"]).joined(separator: "\n")
    }

    static func permission() async {
        var failures = 0
        func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("permission-test: \(n) \(ok ? "ok" : "FAIL")") }

        let long = ApprovalNotice.screenRequest(longPromptScreen())
        let wide = ApprovalNotice.screenRequest(widePromptScreen())
        step("long fixture reads as a card (\(long?.command.split(separator: "\n").count ?? 0) lines)", (long?.command.split(separator: "\n").count ?? 0) > 30)
        step("wide fixture reads as a card (\(wide?.command.count ?? 0) chars)", (wide?.command.count ?? 0) > 1000)

        // "none": the same window without a card, the baseline.
        for (name, request) in [("none", nil), ("long", long), ("wide", wide)] as [(String, PermissionRequest?)] {
            if name != "none", request == nil { continue }
            ApprovalProbe.injected = request
            for (size, full) in [(NSSize(width: 1440, height: 860), true), (NSSize(width: 960, height: 600), false), (NSSize(width: 900, height: 480), false)] {
                ApprovalProbe.cardFrame = .zero
                let model = AppModel(store: .preview)
                if let ws = model.store.workspaces.first(where: { $0.tabs.contains { $0.status == .blocked } }),
                   let t = ws.tabs.first(where: { $0.status == .blocked }) { model.select(tab: t, in: ws) }
                // As the app's window: the content sets only a minimum size, so a card taller than the window would grow it.
                let host = NSHostingView(rootView: RootView(flat: false).environment(model))
                host.sizingOptions = [.minSize]
                let win = OffscreenWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                WindowChrome.apply(win)
                win.contentView = host; win.setContentSize(size); win.setFrameOrigin(NSPoint(x: -4000, y: -3000)); win.orderFrontRegardless()
                if full { ChromeTests.emulateFullScreen(win, model, true) }
                try? await Task.sleep(for: .seconds(2))
                let tag = "\(name)-\(Int(size.width))x\(Int(size.height))\(full ? "-full" : "")"
                let h = win.frame.height, card = ApprovalProbe.cardFrame, pane = QuestionProbe.paneFrame
                let content = host.frame.size
                step("\(tag): window keeps its size (\(Int(content.width))x\(Int(content.height)))",
                     abs(content.width - size.width) < 1 && abs(content.height - size.height) < 1)
                if request != nil {
                    step("\(tag): card shown inside the window (y \(Int(card.minY))..\(Int(card.maxY)) of \(Int(h)), \(Int(card.height)) tall)",
                         card.height > 100 && card.minY >= 0 && card.maxY <= h + 0.5)
                    step("\(tag): pane fits the window (y \(Int(pane.minY))..\(Int(pane.maxY)))", pane.minY >= 0 && pane.maxY <= h + 0.5)
                    step("\(tag): conversation keeps at least \(Int(PaneView.conversationMin)) pt above the card (\(Int(card.minY - pane.minY)))",
                         card.minY - pane.minY >= PaneView.conversationMin)
                }
                if full {
                    let island = TabProbe.island
                    step("\(tag): tab row inside the window (y \(Int(island.minY))..\(Int(island.maxY)))", island.height > 0 && island.minY >= 0 && island.maxY <= h)
                }
                // A window tens of thousands of points tall cannot be captured: the picture is the layout at the asked size.
                host.sizingOptions = []; win.setContentSize(size); try? await Task.sleep(for: .seconds(0.5))
                capture(win, to: "\(dir)/permission-\(tag).png")
                if full { ChromeTests.emulateFullScreen(win, model, false) }
                win.orderOut(nil)
            }
        }
        ApprovalProbe.injected = nil

        print("permission-test: pictures in \(dir)")
        print("permission-test: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        NSApp.terminate(nil)
    }
}
