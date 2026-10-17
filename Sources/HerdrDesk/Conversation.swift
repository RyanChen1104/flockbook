import HerdrKit
import SwiftUI

struct ConversationView: View {
    let items: [ConversationItem]
    let agentName: String
    /// The pending call whose card gets Allow / Deny (`ApprovalNotice.CardPlace.conversation`). Any other pending call
    /// shows a "Running" chip: its id is not the prompt on screen.
    var liveCard: String? = nil
    /// The card's buttons, with the request the card shows (its prompt id binds the keys).
    var onAllow: (PermissionRequest) -> Void = { _ in }
    var onDeny: (PermissionRequest) -> Void = { _ in }
    var onOpenTerminal: () -> Void = {}
    /// The agent's state: picks the empty-state copy (a fresh agent has no log until its first message).
    var agentStatus: AgentStatus? = nil
    /// The fresh-agent empty state appeared: the pane puts the cursor in the composer.
    var onFresh: () -> Void = {}
    /// Load state of the agent's session log (from the store). nil: older callers; `hasLog` then means "may still load".
    var loadState: ConversationLoadState? = nil
    var hasLog = false
    /// Changes when the user sends a message: back to the bottom whatever the position, following from there
    /// (the log shows the sent message a moment later).
    var scrollToken = 0
    /// The session the rows come from. Another session in the pane starts over: it may have older rows to read.
    var session: String? = nil
    /// Reads an older part of the log; true while older content remains. nil hides the button.
    var onLoadEarlier: (() async -> Bool)? = nil
    @State private var moreEarlier = true
    @State private var loadingEarlier = false
    /// Counts the sessions the view showed: a read of an older session's log that ends later changes nothing.
    @State private var earlierSession = 0
    @State private var spinnerDue = false
    /// Rows shown at first; "Show earlier" adds this many again. A check may raise it (a long session read far back).
    static var page = ConversationWindow.page
    /// The rows shown: at most `ConversationWindow.maxRows`, the newest unless "Show earlier" went past that.
    @State private var window = ConversationWindow(shown: ConversationView.page)
    /// Which view set the probe's actions (a replaced view disappears after its successor appeared).
    @State private var probeId = UUID()
    @AppStorage(ReadingSize.key, store: AppDefaults.store) private var sizeRaw = ReadingSize.m.rawValue
    @AppStorage(ReadingWidth.key, store: AppDefaults.store) private var widthRaw = ReadingWidth.medium.rawValue   // re-renders when the width changes
    private var size: ReadingSize { ReadingSize(rawValue: sizeRaw) ?? .m }

    var body: some View {
        if let state = Self.emptyState(items: items, loadState: loadState, hasLog: hasLog) {
            empty(state)
        } else {
            list
        }
    }

    /// Which empty view to show, or nil for the list.
    static func emptyState(items: [ConversationItem], loadState: ConversationLoadState?, hasLog: Bool) -> ConversationLoadState? {
        items.isEmpty ? loadState ?? (hasLog ? .loading : nil) : nil
    }

    struct EmptyCopy: Equatable { var title: String; var detail: String; var terminal = false; var fresh = false }

    /// Words for an empty conversation. A new agent has no session log until its first message: that is not an error, so it
    /// reads "No messages yet" with what to do. "No conversation log" + Show Terminal only when the agent has worked
    /// (working, blocked, done) and its log still cannot be found.
    static func emptyCopy(_ state: ConversationLoadState, status: AgentStatus?, agentName: String) -> EmptyCopy {
        let first = "Send your first message to see the session conversation."
        switch (state, status) {
        case (.missing, .idle?), (.missing, nil):
            return EmptyCopy(title: "No messages yet", detail: first, fresh: true)
        case (.missing, _):
            return EmptyCopy(title: "No conversation log", detail: "\(agentName)'s session log was not found. The terminal shows what it is doing.", terminal: true)
        case (_, .idle?), (_, nil):
            return EmptyCopy(title: "No messages yet", detail: first, fresh: true)
        case (_, .working?):
            return EmptyCopy(title: "No messages yet", detail: "\(agentName) is starting. Its messages appear here.")
        default:
            return EmptyCopy(title: "No messages yet", detail: "\(agentName) has not written anything yet.")
        }
    }

    /// No rows yet: say why. A spinner only once loading has taken longer than half a second.
    @ViewBuilder private func empty(_ state: ConversationLoadState) -> some View {
        switch state {
        case .loading:
            VStack(spacing: 10) {
                if spinnerDue {
                    ProgressView().controlSize(.small)
                    Text("Loading conversation…").font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { try? await Task.sleep(for: .milliseconds(500)); spinnerDue = true }
        case .ready, .missing:
            let copy = Self.emptyCopy(state, status: agentStatus, agentName: agentName)
            if copy.terminal {
                ContentUnavailableView {
                    Label(copy.title, systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text(copy.detail)
                } actions: {
                    Button("Show Terminal", action: onOpenTerminal)
                }
            } else {
                ContentUnavailableView(copy.title, systemImage: "bubble.left.and.bubble.right", description: Text(copy.detail))
                    .onAppear { if copy.fresh { onFresh() } }
            }
        case .failed(let why):
            ContentUnavailableView {
                Label("Can't read the conversation", systemImage: "exclamationmark.triangle")
            } description: {
                Text(why)
            } actions: {
                Button("Show Terminal", action: onOpenTerminal)
            }
        }
    }

    /// Whether the reader sits at the bottom. A plain object, not @State: written from the scroll callback,
    /// so it never triggers a render (writing @State there caused layout feedback loops before).
    @MainActor final class BottomTracker {
        var atBottom = true
        /// The scroll offset, and each row's top in the rows' own space (both as last seen).
        var offset: CGFloat = 0
        var tops: [String: CGFloat] = [:]
        /// While older rows come in above: the row that was on top and where it was, so the view keeps it in place.
        var anchor: (key: String, top: CGFloat, offset: CGFloat, until: Date)?
        /// The top inset as last seen (scrollTo(y:) takes a content point, under it), and a fix of the anchor due next turn.
        var inset: CGFloat = 0
        var fixDue = false
        /// The page the read of the log in flight asked for: half a page when it loads by itself.
        var loadPage = ConversationView.page
    }
    /// Closer than this to the top, the reader's scrolling loads older rows by itself (Show earlier stays as the button).
    /// Half a page at a time: the stack lays out every new row in one pass, and 100 at once came near the 250 ms stall limit.
    static let nearTop: CGFloat = 400
    static var autoPage: Int { max(1, page / 2) }
    @State private var tracker = BottomTracker()
    @State private var position = ScrollPosition(edge: .bottom)

    private var list: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let ids = items.map(\.id)
                    let range = window.range(ids)
                    if range.lowerBound > 0 || (onLoadEarlier != nil && moreEarlier) {
                        Button { showEarlier() } label: {
                            HStack(spacing: 6) {
                                if loadingEarlier { ProgressView().controlSize(.mini) }
                                Text(range.lowerBound > 0 ? "Show earlier (\(range.lowerBound))" : "Show earlier")
                            }
                        }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.bottom, 20).help("Load older messages")
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ConversationProbe.earlier = $0 }
                        .onAppear { ConversationProbe.set(.earlier, probeId) { showEarlier() } }
                        .onDisappear { ConversationProbe.clear(.earlier, probeId) }
                    }
                    let rows = Self.displayRows(items[range])
                    let lastReply = window.detached ? nil : rows.last { if case .assistantText = $0.kind { true } else { false } }?.id
                    let entries = Self.entries(rows)
                    ForEach(Array(entries.enumerated()), id: \.element.key) { i, e in
                        entryView(e, foldable: e.item?.id != lastReply)
                            // The row's own top, without the gap above it (the first row has none; it gets one when older rows come in).
                            // The anchor row moved: older rows came in above (also when as many newer rows left, same height).
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.rowSpace)).minY } action: {
                                tracker.tops[e.key] = $0
                                if tracker.anchor?.key == e.key { holdAnchor() }
                            }
                            .padding(.top, i == 0 ? 0 : e.gap(after: entries[i - 1]))
                    }
                    if window.detached {
                        Button { jumpToLatest() } label: {
                            Label("Jump to latest (\(ids.count - range.upperBound) newer)", systemImage: "arrow.down")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .frame(maxWidth: .infinity).padding(.top, 24).help("Show the newest messages")
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ConversationProbe.latest = $0 }
                        .onAppear { ConversationProbe.set(.latest, probeId) { jumpToLatest() } }
                        .onDisappear { ConversationProbe.latest = .zero; ConversationProbe.clear(.latest, probeId) }
                    }
                }
                .coordinateSpace(.named(Self.rowSpace))
                .frame(maxWidth: size.column, alignment: .leading)
                .padding(.horizontal, (ReadingWidth(rawValue: widthRaw) ?? .medium).sidePadding).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollPosition($position)
            // Following: the reader is "at the bottom" only through their own scrolling (offset changes alone).
            // When the content or the viewport changes size (a new message, a tool result, markdown settling, a window or
            // composer resize, safe-area insets settling) a reader at the bottom stays there.
            // One rule for every growth, so no per-event scroll calls and no retry timers.
            .onScrollGeometryChange(for: ScrollMetrics.self) { g in
                ScrollMetrics(offset: g.contentOffset.y, content: g.contentSize.height, container: g.containerSize.height,
                              insets: g.contentInsets.top + g.contentInsets.bottom, top: g.contentInsets.top)
            } action: { old, new in
                tracker.inset = new.top
                if abs(new.content - old.content) > 0.5 || abs(new.container - old.container) > 0.5 || abs(new.insets - old.insets) > 0.5 {
                    if tracker.atBottom {
                        // Next turn of the run loop: scrolling inside the update pass makes SwiftUI report "multiple times per frame".
                        Task { @MainActor in position.scrollTo(edge: .bottom) }
                    } else {
                        holdAnchor()
                    }
                } else {
                    tracker.atBottom = new.atBottom
                    tracker.offset = new.offset
                    if let a = tracker.anchor, let top = tracker.tops[a.key] { tracker.anchor = (a.key, top, new.offset, a.until) }
                    // The reader came near the top: older rows load by themselves.
                    if new.offset + new.top < Self.nearTop, old.offset + old.top >= Self.nearTop { Task { @MainActor in showEarlier(page: Self.autoPage) } }
                }
            }
            .onChange(of: scrollToken) { _, _ in jumpToLatest() }
            .onChange(of: session) { _, _ in earlierSession += 1; moreEarlier = true; loadingEarlier = false }
            .onChange(of: items.first?.id) { _, _ in
                // Older rows arrived in front after "Show earlier" read the log: the window takes a page of them.
                if window.takeLoaded(items.map(\.id), page: tracker.loadPage), let a = tracker.anchor { tracker.anchor?.until = max(a.until, Date().addingTimeInterval(1.5)) }
            }
    }

    /// A page of older rows: from the rows at hand, else read from the log (the window takes them when they arrive).
    private func showEarlier(page: Int = Self.page) {
        let ids = items.map(\.id)
        if window.range(ids).lowerBound > 0 { keepTop(ids); window.showEarlier(ids, page: page); return }
        guard let load = onLoadEarlier, moreEarlier, !loadingEarlier else { return }
        loadingEarlier = true
        tracker.loadPage = page
        keepTop(ids, for: 4)
        let token = window.beginLoad(), mine = earlierSession
        Task {
            let more = await load()
            if earlierSession == mine { moreEarlier = more; loadingEarlier = false }
            try? await Task.sleep(for: .seconds(3)); window.loadEnded(token)   // nothing arrived (a newer read stays pending)
        }
    }

    /// The row now on top of the window stays where it is on screen while older rows come in above it (for `seconds`).
    private func keepTop(_ ids: [String], for seconds: Double = 1.5) {
        guard let key = Self.anchorKey(Self.entries(Self.displayRows(items[window.range(ids)]))), let top = tracker.tops[key] else { return }
        tracker.anchor = (key, top, tracker.offset, Date().addingTimeInterval(seconds))
    }

    /// The row to keep in place: the first that is not a tool row. A tool row on top merges with an older tool row that
    /// comes in above it and takes that row's id, so its key would be gone.
    static func anchorKey(_ entries: [Entry]) -> String? {
        (entries.first { if case .row(let i) = $0.kind, case .toolChips = i.kind { false } else if case .row = $0.kind { true } else { false } } ?? entries.first)?.key
    }

    /// Older rows came in above and moved the anchor row: the view moves by as much. Next turn of the run loop, after the
    /// update pass, when every row reported its new top (scrolling inside the pass makes SwiftUI report "multiple times per frame").
    private func holdAnchor() {
        guard !tracker.fixDue else { return }
        tracker.fixDue = true
        Task { @MainActor in
            tracker.fixDue = false
            guard !tracker.atBottom, let a = tracker.anchor, a.until > Date(), let top = tracker.tops[a.key], abs(top - a.top) > 0.5 else { return }
            let offset = a.offset + top - a.top
            position.scrollTo(y: offset + tracker.inset)
            tracker.anchor = (a.key, top, offset, a.until)
        }
    }

    /// The newest page, at the bottom, following again.
    private func jumpToLatest() {
        window.jumpToLatest(page: Self.page)
        tracker.atBottom = true
        tracker.anchor = nil
        Task { @MainActor in position.scrollTo(edge: .bottom) }
    }

    struct ScrollMetrics: Equatable {
        var offset: CGFloat; var content: CGFloat; var container: CGFloat; var insets: CGFloat; var top: CGFloat
        /// The newest row is in view (within 40 pt). The container is the area between the bars, and the offset starts
        /// above the top bar: at the end, offset + top + container = content. Leaving out `top` read a reader at the end
        /// as scrolled up whenever the top bar was over 40 pt (the toolbar and a pane label), and following stopped.
        var atBottom: Bool { offset + top + container >= content - 40 }
    }
    static let rowSpace = "conversation-rows"

    struct Entry {
        enum Kind { case row(ConversationItem), separator(String), footer(String) }
        let key: String
        let kind: Kind
        /// The last real row before this entry, for the usual row-to-row gap.
        let prevRow: ConversationItem?
        var item: ConversationItem? { if case .row(let i) = kind { i } else { nil } }
        func gap(after prev: Entry) -> CGFloat {
            switch (prev.kind, kind) {
            case (.separator, _), (_, .separator): return 24
            case (_, .footer): return 12
            case (.footer, .row(let i)): return prev.prevRow.map { ConversationView.gap($0, i) } ?? 14
            case (.row(let a), .row(let b)): return ConversationView.gap(a, b)
            default: return 14
            }
        }
    }

    /// Rows plus time separators (gap >= 15 min or a new day) and one footer per agent turn.
    static func entries(_ rows: [ConversationItem]) -> [Entry] {
        var out: [Entry] = []
        var prevTime: Date?, prevRow: ConversationItem?
        var turnStart: Date?, turnTools = 0, turnHasReply = false, turnEnd: Date?
        func closeTurn() {
            guard turnHasReply, let end = turnEnd, let last = prevRow else { return }
            var parts = [clock(end)]
            if let s = turnStart, end.timeIntervalSince(s) >= 1 { parts.append("Worked \(duration(end.timeIntervalSince(s)))") }
            if turnTools > 0 { parts.append("\(turnTools) tool\(turnTools == 1 ? "" : "s")") }
            out.append(Entry(key: "f-\(last.id)", kind: .footer(parts.joined(separator: " · ")), prevRow: last))
        }
        for it in rows {
            if case .userText = it.kind { closeTurn(); turnStart = it.timestamp; turnTools = 0; turnHasReply = false; turnEnd = nil }
            if let t = it.timestamp {
                if let p = prevTime, t.timeIntervalSince(p) >= 900 || !Calendar.current.isDate(t, inSameDayAs: p) {
                    out.append(Entry(key: "s-\(it.id)", kind: .separator(separatorText(t)), prevRow: prevRow))
                }
                prevTime = t; turnEnd = t
            }
            if case .assistantText = it.kind { turnHasReply = true }
            if case .toolChips(let c) = it.kind { turnTools += c.reduce(0) { $0 + max(1, $1.calls.count) } }
            out.append(Entry(key: "r-\(it.id)", kind: .row(it), prevRow: prevRow))
            prevRow = it
        }
        closeTurn()
        return out
    }

    private static func clock(_ d: Date) -> String { d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
    private static func duration(_ s: TimeInterval) -> String {
        let n = Int(s.rounded())
        return n >= 3600 ? "\(n / 3600)h \(n % 3600 / 60)m" : n >= 60 ? "\(n / 60)m \(n % 60)s" : "\(n)s"
    }
    private static func separatorText(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return clock(d) }
        if cal.isDateInYesterday(d) { return "Yesterday \(clock(d))" }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " " + clock(d)
    }

    @ViewBuilder private func entryView(_ e: Entry, foldable: Bool) -> some View {
        switch e.kind {
        case .row(let item): row(item, foldable: foldable).id(item.id)
        case .separator(let t):
            HStack(spacing: 10) {
                Rectangle().fill(ReadingColor.hairline).frame(width: 48, height: 0.5)
                Text(t).font(.subheadline.weight(.medium).monospacedDigit()).foregroundStyle(.tertiary)
                Rectangle().fill(ReadingColor.hairline).frame(width: 48, height: 0.5)
            }
            .frame(maxWidth: .infinity)
        case .footer(let t):
            Text(t).font(.subheadline.weight(.medium).monospacedDigit()).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Adjacent tool-chip items form one chip row.
    static func displayRows(_ items: ArraySlice<ConversationItem>) -> [ConversationItem] {
        var out: [ConversationItem] = []
        for it in items {
            if case .toolChips(let c) = it.kind, let last = out.last, case .toolChips(let prev) = last.kind {
                out[out.count - 1] = ConversationItem(id: last.id, kind: .toolChips(prev + c), timestamp: last.timestamp)
            } else { out.append(it) }
        }
        return out
    }

    /// Vertical gap between rows (reading.md §3): 32 before a user bubble, 20 after it, 8 around chips.
    static func gap(_ a: ConversationItem, _ b: ConversationItem) -> CGFloat {
        switch (a.kind, b.kind) {
        case (_, .userText): return 32
        case (.userText, _): return 20
        case (.toolChips, _), (_, .toolChips): return 8
        case (_, .status), (.status, _): return 16
        default: return 14
        }
    }

    @ViewBuilder private func row(_ item: ConversationItem, foldable: Bool) -> some View {
        switch item.kind {
        case .userText(let t):
            HStack {
                Spacer(minLength: min(size.column * 0.2, 120))
                UserBubble(text: t, size: size)
            }
        case .assistantText(let t):
            MarkdownView(text: t, foldable: foldable)
        case .toolChips(let chips):
            ChipGroup(chips: chips)
        case .permissionRequest(let r):
            if r.state == .pending {
                if r.toolUseId == liveCard { approval(r) } else { FlowLayout(spacing: 6) { ChipView(chip: ToolChip(symbol: "hourglass", text: "Running \(r.toolName.isEmpty ? "tool" : r.toolName)…")) } }
            }
        case .status(let s):
            Text(s).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        case .question(let q):
            // Pending: the card stands in the composer slot (PaneView); answered or declined: one row here.
            if q.state != .pending { QuestionAnsweredRow(model: q, time: item.timestamp) }
        }
    }

    @ViewBuilder private func approval(_ r: PermissionRequest) -> some View {
        ApprovalCard(request: r, agentName: agentName, canRespond: true, onAllow: { onAllow(r) }, onDeny: { onDeny(r) }, onOpen: onOpenTerminal)
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Where the conversation's Show earlier and Jump to latest buttons sit (window coordinates, top left), for the checks.
/// The checks press them through the actions (a synthetic click does not reach a button in a scroll view of a window that is
/// not key, and a headless run never has a key window).
@MainActor enum ConversationProbe {
    /// Only a check turns them on: the actions keep the view's state alive.
    static var enabled = false
    static var earlier = CGRect.zero, latest = CGRect.zero
    private(set) static var pressEarlier: (() -> Void)?, pressLatest: (() -> Void)?
    private static var owners: [Button: UUID] = [:]
    enum Button { case earlier, latest }

    static func set(_ b: Button, _ owner: UUID, _ action: @escaping () -> Void) {
        guard enabled else { return }
        owners[b] = owner
        if b == .earlier { pressEarlier = action } else { pressLatest = action }
    }

    /// Only the view that set the action clears it.
    static func clear(_ b: Button, _ owner: UUID) {
        guard owners[b] == owner else { return }
        owners[b] = nil
        if b == .earlier { pressEarlier = nil } else { pressLatest = nil }
    }
}

/// Gray bubble, right aligned, inline markdown only (reading.md §10).
struct UserBubble: View {
    let text: String
    let size: ReadingSize
    var body: some View {
        MessageText(content: .bubble(text, size: size), fit: true)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.bubble))
            .frame(maxWidth: size.column * 0.8, alignment: .trailing)
    }
}

struct ChipView: View {
    let chip: ToolChip
    var expanded = false
    @State private var hover = false
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: chip.symbol).font(.subheadline).foregroundStyle(.secondary)
            Text(chip.text).font(.callout.weight(.medium)).foregroundStyle(chip.calls.contains { $0.isError } ? Color.primary : Color.secondary)
            if !chip.calls.isEmpty {
                Image(systemName: "chevron.right").font(.caption2).imageScale(.small).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(Color.primary.opacity(hover && !chip.calls.isEmpty ? 0.12 : 0.07), in: Capsule())
        .contentShape(Capsule())
        .onHover { hover = $0 }
    }
}

/// A row of tool chips. Clicking a chip expands its calls below (no popover); clicking a call shows input/output.
struct ChipGroup: View {
    let chips: [ToolChip]
    @State private var open: Int?
    @State private var openCall: String?
    @State private var showAll = false
    private var visible: [ToolChip] { chips.count > 5 && !showAll ? Array(chips.prefix(4)) : chips }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(Array(visible.enumerated()), id: \.offset) { i, chip in
                    Button {
                        guard !chip.calls.isEmpty else { return }
                        withAnimation(.snappy(duration: 0.15)) { open = open == i ? nil : i; openCall = nil }
                    } label: { ChipView(chip: chip, expanded: open == i) }
                    .buttonStyle(.plain)
                    .help(chip.calls.isEmpty ? chip.text : "Show calls")
                }
                if chips.count > 5 {
                    Button { withAnimation(.snappy(duration: 0.15)) { showAll.toggle(); open = nil } } label: {
                        ChipView(chip: ToolChip(symbol: showAll ? "chevron.up" : "ellipsis", text: showAll ? "Show fewer" : "+\(chips.count - 4) more"))
                    }
                    .buttonStyle(.plain)
                }
            }
            if let i = open, visible.indices.contains(i) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(visible[i].calls) { call in callRow(call, symbol: visible[i].symbol) }
                }
                .padding(6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.card))
            }
        }
    }

    @ViewBuilder private func callRow(_ call: ToolCall, symbol: String) -> some View {
        let isOpen = openCall == call.id
        CallHeader(call: call, symbol: symbol, isOpen: isOpen) {
            withAnimation(.snappy(duration: 0.15)) { openCall = isOpen ? nil : call.id }
        }
        if isOpen {
            VStack(alignment: .leading, spacing: 6) {
                CodeBox(label: "Input", text: call.input)
                if let out = call.output { CodeBox(label: call.isError ? "Error" : "Output", text: out, isError: call.isError) }
                else { Text("Running…").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.leading, 22).padding(.bottom, 4)
        }
    }
}

private struct CallHeader: View {
    let call: ToolCall
    let symbol: String
    let isOpen: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.subheadline).foregroundStyle(.secondary).frame(width: 14)
                Text(call.summary.isEmpty ? call.toolName : call.summary)
                    .font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if call.isError { Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red) }
                else if call.output == nil { ProgressView().controlSize(.mini) }
                Image(systemName: "chevron.right").font(.caption2).imageScale(.small).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .padding(.horizontal, 6).frame(height: 24)
            .background(Color.primary.opacity(hover ? 0.07 : 0), in: RoundedRectangle(cornerRadius: Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(call.toolName)
    }
}

private struct CodeBox: View {
    let label: String
    let text: String
    var isError = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.vertical) {
                MessageText(content: .plain(text.isEmpty ? "(empty)" : text, monoSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
                                            error: isError))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(maxHeight: 190)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.control))
        }
    }
}

struct ApprovalCard: View {
    let request: PermissionRequest
    let agentName: String
    var canRespond = false
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark")
                    .font(.body.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: Radius.control))
                Text(request.title).font(.headline)
            }
            MessageText(content: .plain(request.command, monoSize: NSFont.preferredFont(forTextStyle: .callout).pointSize))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.control))
            HStack {
                if canRespond {
                    Button(action: onOpen) { Label("Open terminal", systemImage: "apple.terminal") }
                    Spacer()
                    Button("Deny", action: onDeny)
                    Button("Allow", action: onAllow).buttonStyle(.borderedProminent)
                } else {
                    Spacer()
                    Button(action: onOpen) { Label("Open terminal", systemImage: "apple.terminal") }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .glassCard(radius: Radius.card, tint: .orange.opacity(0.08))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(bounds.width, subviews)
        for (i, p) in r.points.enumerated() { subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified) }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        var pts: [CGPoint] = []
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            pts.append(CGPoint(x: x, y: y))
            x += sz.width + spacing; rowH = max(rowH, sz.height); maxW = max(maxW, x - spacing)
        }
        return (CGSize(width: maxW, height: y + rowH), pts)
    }
}
