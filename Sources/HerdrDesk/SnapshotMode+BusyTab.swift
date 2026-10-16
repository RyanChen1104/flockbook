import AppKit
import HerdrKit
import SwiftUI

/// Offscreen check of a busy tab (`--test-busy-tab`): four panes side by side, each a long conversation (a page of 100 rows of text),
/// one agent writing. A new row must cost about one new text, not a rebuild of every text on screen; with nothing new,
/// the main thread must rest. Synthetic items only. Under 30 s.
extension ContentTests {
    static func busyTab() async {
        var failures = 0
        func step(_ n: String, _ ok: Bool) { if !ok { failures += 1 }; print("busy-tab: \(n) \(ok ? "ok" : "FAIL")") }
        let panes = 4, rows = ConversationWindow.maxRows, page = ConversationView.page
        // Texts of other tabs read earlier, 2 KB each: the store is full before this tab opens.
        let filler = String(repeating: "tool output line ", count: 120)
        for i in 0..<MessageContent.keep { _ = MessageContent.plain("other tab \(i) " + filler, monoSize: 12) }
        print("busy-tab: memory before this tab: \(footprint() / 1_048_576) MB (phys_footprint)")
        let holder = BusyHolder(panes: (0..<panes).map { p in BusyData.items(p, rows) })
        let size = NSSize(width: 1600, height: 900)
        let host = NSHostingView(rootView: BusyView(holder: holder))
        host.frame = NSRect(origin: .zero, size: size)
        let win = OffscreenWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.contentView = host; win.setFrameOrigin(NSPoint(x: -3000, y: -3000)); win.orderFrontRegardless()
        host.layoutSubtreeIfNeeded(); win.displayIfNeeded()
        try? await Task.sleep(for: .seconds(2))
        let shown = Self.all(MessageTextView.self, in: host).count
        step("first view: \(shown) message text views in \(panes) panes", shown == panes * page)

        // At rest: nothing new, so no text is built or measured again.
        var b0 = MessageContent.builds, m0 = MessageContent.measures
        try? await Task.sleep(for: .seconds(2))
        step("at rest: \(MessageContent.builds - b0) texts built, \(MessageContent.measures - m0) measured in 2 s (want 0)",
             MessageContent.builds == b0 && MessageContent.measures == m0)

        // One agent writes: each new row costs its own text, not every text on screen again.
        b0 = MessageContent.builds; m0 = MessageContent.measures
        var layout: [Double] = []
        for i in 0..<10 {
            holder.panes[0].append(ConversationItem(id: "new\(i)", kind: .assistantText("New reply \(i): the agent keeps writing while the other panes wait."),
                                                    timestamp: Date(timeIntervalSince1970: 1_900_000_000 + Double(i))))
            let t = Date()
            host.layoutSubtreeIfNeeded(); win.displayIfNeeded()
            layout.append(Date().timeIntervalSince(t) * 1000)
            try? await Task.sleep(for: .milliseconds(100))
        }
        let built = MessageContent.builds - b0, measured = MessageContent.measures - m0
        print("busy-tab: layout and draw after a new row: \(layout.map { Int($0) }) ms")
        step("10 new rows: \(built) texts built (want at most 40)", built <= 40)
        step("10 new rows: \(measured) texts measured (want at most 80)", measured <= 80)

        // The store fills up while the tab is on screen (other tabs, long tool output): a text on screen keeps its content,
        // so an update after that does not rebuild, reload or measure it.
        let before = Dictionary(Self.all(MessageTextView.self, in: host).map { (ObjectIdentifier($0), $0.contentID) }) { a, _ in a }
        let filler2 = String(repeating: "more tool output ", count: 120)
        for i in 0..<MessageContent.keep { _ = MessageContent.plain("later tab \(i) " + filler2, monoSize: 12) }
        b0 = MessageContent.builds; m0 = MessageContent.measures
        for p in 0..<panes {
            holder.panes[p].append(ConversationItem(id: "full\(p)", kind: .assistantText("New reply in pane \(p) after a full store."),
                                                    timestamp: Date(timeIntervalSince1970: 1_950_000_000 + Double(p))))
        }
        host.layoutSubtreeIfNeeded(); win.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        let views = Self.all(MessageTextView.self, in: host)
        let changed = views.filter { v in before[ObjectIdentifier(v)].map { $0 != v.contentID } ?? false }.count
        let after = MessageContent.builds - b0, measuredAfter = MessageContent.measures - m0
        print("busy-tab: memory with a full store: \(footprint() / 1_048_576) MB (phys_footprint)")
        step("full store, \(panes) new rows: \(changed) texts on screen reloaded (want 0)", changed == 0)
        step("full store, \(panes) new rows: \(after) texts built, \(measuredAfter) measured (want at most \(2 * panes), \(10 * panes))",
             after <= 2 * panes && measuredAfter <= 10 * panes)

        // Long texts (tool output): the store keeps at most `keepChars` characters, also with one text larger than that.
        let big = String(repeating: "0123456789 ", count: 100_000)   // 1.1 M characters
        var held: [MessageContent] = []
        for i in 0..<4 { held.append(MessageContent.plain("\(i) " + big, monoSize: 12)) }
        step("long texts: \(MessageContent.chars) characters stored (at most \(MessageContent.keepChars))", MessageContent.chars <= MessageContent.keepChars)
        // Four long outputs in view at once: each keeps its content while held, however full the store is.
        let again = (0..<4).map { MessageContent.plain("\($0) " + big, monoSize: 12) }
        step("long texts: a long text in use keeps its content", zip(held, again).allSatisfy { $0 === $1 })
        let huge = String(repeating: "0123456789 ", count: 400_000)   // 4.4 M characters, source and text over 8 M
        let hugeContent = MessageContent.plain(huge, monoSize: 12)
        step("one text over the limit: \(MessageContent.chars) characters stored (at most \(MessageContent.keepChars))",
             MessageContent.chars <= MessageContent.keepChars && MessageContent.plain(huge, monoSize: 12) === hugeContent)
        print("busy-tab: memory \(footprint() / 1_048_576) MB (phys_footprint)")
        withExtendedLifetime((held, hugeContent)) {}

        win.orderOut(nil)
        print("busy-tab: \(failures == 0 ? "PASS" : "FAIL x\(failures)")")
        exit(failures == 0 ? 0 : 1)
    }
}

/// The process's physical footprint in bytes (Activity Monitor's "Memory").
private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return r == KERN_SUCCESS ? info.phys_footprint : 0
}

@MainActor @Observable private final class BusyHolder {
    var panes: [[ConversationItem]]
    init(panes: [[ConversationItem]]) { self.panes = panes }
}

private struct BusyView: View {
    let holder: BusyHolder
    var body: some View {
        HStack(spacing: 0) {
            ForEach(holder.panes.indices, id: \.self) { p in
                ConversationView(items: holder.panes[p], agentName: "pane\(p)", loadState: .ready)
            }
        }
    }
}

/// Every row a message with its own text: user turns and short replies.
private enum BusyData {
    static func items(_ pane: Int, _ n: Int) -> [ConversationItem] {
        (0..<n).map { i in
            let t = Date(timeIntervalSince1970: 1_800_000_000 + Double(i * 37))
            return i % 2 == 0
                ? ConversationItem(id: "p\(pane)u\(i)", kind: .userText("Pane \(pane), step \(i): check the parser."), timestamp: t)
                : ConversationItem(id: "p\(pane)a\(i)", kind: .assistantText("Pane \(pane), step \(i) done. The reader wraps this text to the column."), timestamp: t)
        }
    }
}
