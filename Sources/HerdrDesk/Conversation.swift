import HerdrKit
import SwiftUI

struct ConversationView: View {
    let items: [ConversationItem]
    let agentName: String
    var canRespond = false
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
    /// Reads an older part of the log; true while older content remains. nil hides the button.
    var onLoadEarlier: (() async -> Bool)? = nil
    @State private var moreEarlier = true
    @State private var loadingEarlier = false
    @State private var spinnerDue = false
    /// Rows shown at first; "Show earlier" adds this many again. A check may raise it (a long session read far back).
    static var page = ConversationWindow.page
    /// The rows shown: at most `ConversationWindow.maxRows`, the newest unless "Show earlier" went past that.
    @State private var window = ConversationWindow(shown: ConversationView.page)
    /// Which view set the probe's actions (a replaced view disappears after its successor appeared).
    @State private var probeId = UUID()
    /// The one row whose text can be selected: the last one under the pointer.
    @State private var selectableKey: String?
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
    @MainActor final class BottomTracker { var atBottom = true }
    @State private var tracker = BottomTracker()
    @State private var position = ScrollPosition(edge: .bottom)

    private var list: some View {
        ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
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
                            // Selectable only under the pointer (see `selectableText`). Leaving a row keeps it selectable,
                            // so a selection made there stays until the pointer reaches another row.
                            .environment(\.selectableText, selectableKey == e.key)
                            .onHover { if $0, selectableKey != e.key { selectableKey = e.key } }
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
                              insets: g.contentInsets.top + g.contentInsets.bottom)
            } action: { old, new in
                if abs(new.content - old.content) > 0.5 || abs(new.container - old.container) > 0.5 || abs(new.insets - old.insets) > 0.5 {
                    if tracker.atBottom {
                        // Next turn of the run loop: scrolling inside the update pass makes SwiftUI report "multiple times per frame".
                        Task { @MainActor in position.scrollTo(edge: .bottom) }
                    }
                } else {
                    tracker.atBottom = new.offset + new.container >= new.content - 40
                }
            }
            .onChange(of: scrollToken) { _, _ in jumpToLatest() }
            .onChange(of: items.first?.id) { _, _ in
                // Older rows arrived in front after "Show earlier" read the log: the window takes a page of them.
                window.takeLoaded(items.map(\.id), page: Self.page)
            }
    }

    /// A page of older rows: from the rows at hand, else read from the log (the window takes them when they arrive).
    private func showEarlier() {
        let ids = items.map(\.id)
        if window.range(ids).lowerBound > 0 { window.showEarlier(ids, page: Self.page); return }
        guard let load = onLoadEarlier, !loadingEarlier else { return }
        loadingEarlier = true
        let token = window.beginLoad()
        Task {
            moreEarlier = await load(); loadingEarlier = false
            try? await Task.sleep(for: .seconds(3)); window.loadEnded(token)   // nothing arrived (a newer read stays pending)
        }
    }

    /// The newest page, at the bottom, following again.
    private func jumpToLatest() {
        window.jumpToLatest(page: Self.page)
        tracker.atBottom = true
        Task { @MainActor in position.scrollTo(edge: .bottom) }
    }

    struct ScrollMetrics: Equatable { var offset: CGFloat; var content: CGFloat; var container: CGFloat; var insets: CGFloat }

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
                if canRespond { approval(r) } else { FlowLayout(spacing: 6) { ChipView(chip: ToolChip(symbol: "hourglass", text: "Running \(r.toolName.isEmpty ? "tool" : r.toolName)…")) } }
            }
        case .status(let s):
            Text(s).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        case .question(let q):
            // Pending: the card stands in the composer slot (PaneView); answered or declined: one row here.
            if q.state != .pending { QuestionAnsweredRow(model: q, time: item.timestamp) }
        }
    }

    @ViewBuilder private func approval(_ r: PermissionRequest) -> some View {
        ApprovalCard(request: r, agentName: agentName, canRespond: canRespond, onAllow: { onAllow(r) }, onDeny: { onDeny(r) }, onOpen: onOpenTerminal)
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
        let a = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        Text(a).font(.system(size: size.body)).lineSpacing(max(0, size.line - 2 - size.body * 1.19)).selectableText()
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
                if let out = call.output { CodeBox(label: call.isError ? "Error" : "Output", text: out, tint: call.isError ? .red : nil) }
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
    var tint: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.vertical) {
                Text(text.isEmpty ? "(empty)" : text)
                    .font(.system(.subheadline, design: .monospaced)).foregroundStyle(tint ?? .primary)
                    .selectableText()
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
            Text(request.command)
                .font(.system(.callout, design: .monospaced)).selectableText()
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
