import AppKit
import HerdrKit
import SwiftUI

/// Answer text as Claude Code reports it keeps the raw label ("Local file (Recommended)"); the card shows labels without it.
enum QuestionText {
    static let suffixes = [" (Recommended)", "(Recommended)", "（建議）", "（推薦）"]
    static func shown(_ answer: String) -> String {
        suffixes.reduce(answer) { $0.replacingOccurrences(of: $1, with: "") }
    }
}

/// The card's answers in progress: pure state, so keys and clicks share one path and a test can drive it.
struct QuestionFlow: Equatable {
    private(set) var questions: [QuestionRequest.Question]
    /// Every question's header from Claude's picker tab bar (empty for log items). More headers than questions: the rest
    /// are not read yet (`HerdrClient.loadAllQuestions` reads them, on a user action only).
    var headers: [String] = []
    var step = 0
    var picks: [Set<Int>]
    var other: [String]
    /// The option picked last (the card scrolls it into view).
    var lastPick: Int?

    init(_ questions: [QuestionRequest.Question], headers: [String] = []) {
        self.questions = questions
        self.headers = headers
        picks = questions.map { _ in [] }
        other = questions.map { _ in "" }
    }

    var question: QuestionRequest.Question { questions[step] }
    /// Questions in all, read or not.
    var total: Int { max(questions.count, headers.count) }
    var isLast: Bool { step == total - 1 }
    /// Going on from here needs the questions not read yet.
    var needsLoad: Bool { step == questions.count - 1 && !isLast }
    /// The header chip: the question's own, else the tab bar's (Claude's screen read leaves it empty with several).
    var header: String { question.header.isEmpty && headers.indices.contains(step) ? headers[step] : question.header }

    /// All questions, once read: answers so far stay.
    mutating func load(_ all: [QuestionRequest.Question]) {
        guard all.count >= questions.count else { return }
        questions = all
        picks += Array(repeating: [], count: all.count - picks.count)
        other += Array(repeating: "", count: all.count - other.count)
    }
    /// The current question has a pick or an "Other" answer.
    var valid: Bool { !picks[step].isEmpty || !other[step].trimmingCharacters(in: .whitespaces).isEmpty }
    /// Number key of the "Other" field (single choice): the one after the last option.
    var otherKey: Int { question.options.count + 1 }

    enum Digit { case picked, other, ignored }
    /// 1…n picks option n (toggles in multiSelect); n+1 goes to "Other" in single choice.
    mutating func digit(_ n: Int) -> Digit {
        if (1...question.options.count).contains(n) { pick(n - 1); return .picked }
        if n == otherKey, !question.multiSelect { return .other }
        return .ignored
    }

    mutating func pick(_ i: Int) {
        lastPick = i
        if question.multiSelect {
            if picks[step].contains(i) { picks[step].remove(i) } else { picks[step].insert(i) }
        } else {
            picks[step] = [i]; other[step] = ""
        }
    }

    /// Typing an "Other" answer in single choice replaces the pick.
    mutating func setOther(_ s: String) {
        other[step] = s
        if !question.multiSelect, !s.trimmingCharacters(in: .whitespaces).isEmpty { picks[step] = [] }
    }

    /// Return: next question, or true when the last one is answered (time to send).
    mutating func advance() -> Bool {
        guard valid else { return false }
        if isLast { return true }
        guard step + 1 < questions.count else { return false }   // not read yet: `load` first
        step += 1
        return false
    }

    mutating func back() { if step > 0 { step -= 1 } }

    /// What `HerdrClient.answerQuestion` takes: 0-based picks in option order, and the "Other" text if any.
    func values() -> [QuestionAnswer] {
        questions.indices.map { k in
            let o = other[k].trimmingCharacters(in: .whitespaces)
            return QuestionAnswer(picks: picks[k].sorted(), other: o.isEmpty ? nil : o)
        }
    }

    /// One string per question, as HerdrKit reports answers: labels in option order joined ", ", then the "Other" text.
    func answers() -> [String] {
        questions.indices.map { k in
            var parts = picks[k].sorted().map { questions[k].options[$0].label }
            let o = other[k].trimmingCharacters(in: .whitespaces)
            if !o.isEmpty { parts.append(o) }
            return parts.joined(separator: ", ")
        }
    }
}

/// Test hook for the live check (`--test-question-live`): what the card did. nil in the app.
@MainActor enum QuestionProbe {
    enum Event { case appeared(QuestionRequest), flow(QuestionFlow), loaded(Int), sent, failed(String) }
    static var report: ((Event) -> Void)?
    /// Tests: the question every blocked pane shows, as if read from its screen.
    static var injected: QuestionRequest?
    /// The card's global frame, last reported (tests).
    static var cardFrame = CGRect.zero
    /// The pane's global frame, last reported (tests).
    static var paneFrame = CGRect.zero
}

/// AskUserQuestion in the composer slot: number keys pick, Return goes on or sends, Esc leaves "Other" or goes back one
/// question. `canSend` off (read-only Desk, or an answer Desk cannot deliver): the card says to answer in the terminal.
struct QuestionCard: View {
    let model: QuestionRequest
    let agentName: String
    var canSend = false
    /// The card's height limit; the question and its options scroll inside when they do not fit.
    var maxHeight: CGFloat = .infinity
    /// Delivers the answers (HerdrClient.answerQuestion); a thrown error shows on the card and the answers stay.
    var onSend: ([QuestionAnswer]) async throws -> Void = { _ in }
    /// Reads the questions not read yet (HerdrClient.loadAllQuestions: moves Claude's picker). Called only when the user
    /// goes on from the last read question, never on its own.
    var onLoadAll: () async throws -> QuestionRequest? = { nil }
    /// Tests: the answers in progress after each change.
    var onFlow: ((QuestionFlow) -> Void)? = nil
    @State private var flow: QuestionFlow
    @State private var sent = false
    @State private var busy = false
    @State private var problem: String?
    /// Height of the question and options (the scrolled part) and of the rest of the card.
    @State private var bodyHeight: CGFloat = 0
    @State private var chrome: CGFloat = 0
    @FocusState private var focus: Field?
    enum Field: Hashable { case card, other }

    init(model: QuestionRequest, agentName: String, canSend: Bool = false, maxHeight: CGFloat = .infinity,
         onSend: @escaping ([QuestionAnswer]) async throws -> Void = { _ in },
         onLoadAll: @escaping () async throws -> QuestionRequest? = { nil },
         onFlow: ((QuestionFlow) -> Void)? = nil) {
        self.model = model; self.agentName = agentName; self.canSend = canSend; self.maxHeight = maxHeight; self.onSend = onSend; self.onLoadAll = onLoadAll
        self.onFlow = onFlow
        _flow = State(initialValue: QuestionFlow(model.questions, headers: model.headers))
    }

    /// Words for a failed send or read. Nothing was typed for `.notOnScreen` and `.unsupported`.
    static func problemText(_ error: Error) -> String {
        switch error as? QuestionAdapter.Failure {
        case .notOnScreen?: "The question is no longer on screen. Nothing was sent."
        case .unsupported(let why)?: "Desk cannot send this answer (\(why)). Nothing was sent. Answer in the terminal."
        case .stuck?: "The terminal did not move on as expected. Check it before you try again."
        case .stillOnScreen?: "The question is still on screen. Check the terminal."
        case nil: "Could not reach the terminal: \(error.localizedDescription)"
        }
    }

    var body: some View {
        Group {
            if sent {
                Text("Sent. \(agentName) is continuing.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            } else {
                card
            }
        }
        .onAppear { onFlow?(flow); QuestionProbe.report?(.appeared(model)); QuestionProbe.report?(.flow(flow)) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { QuestionProbe.cardFrame = $0 }
        .onChange(of: flow) { _, f in onFlow?(f); QuestionProbe.report?(.flow(f)) }
    }

    private var card: some View {
        let q = flow.question
        return VStack(alignment: .leading, spacing: 12) {
            head(q)
            // The question and options scroll inside a capped height, so a long question never makes the card (and the
            // pane) taller than the window. Its height is measured, never taken from the text's own (narrow-width) size.
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(q.text).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                            if q.multiSelect { Text("Choose any.").font(.caption).foregroundStyle(.tertiary) }
                        }
                        VStack(spacing: 6) {
                            ForEach(Array(q.options.enumerated()), id: \.offset) { i, o in optionRow(i, o, multi: q.multiSelect).id(i) }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: scrollHeight)
                .onChange(of: flow.lastPick) { _, i in if let i { withAnimation { reader.scrollTo(i) } } }
            }
            otherRow(q)
            foot(q)
        }
        .padding(16)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chrome = $0 - scrollHeight }
        .glassCard(radius: Radius.bubble, tint: .orange.opacity(0.08))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .card)
        .onKeyPress(phases: .down) { press in key(press) }
        .onAppear { focus = .card }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(agentName) asks you")
    }

    /// The scrolled part's height: all of it when it fits under `maxHeight`, else what is left after the rest of the card.
    private var scrollHeight: CGFloat { min(bodyHeight, max(80, maxHeight - chrome)) }

    private func head(_ q: QuestionRequest.Question) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark").font(.callout.weight(.bold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: Radius.control))
            Text("\(Text(agentName).fontWeight(.semibold).foregroundStyle(.primary)) asks you").foregroundStyle(.secondary)
                .font(.callout).lineLimit(1)
            Spacer(minLength: 8)
            if flow.total > 1 {
                HStack(spacing: 4) {
                    ForEach(0..<flow.total, id: \.self) { k in
                        Capsule().fill(k == flow.step ? Color.orange : k < flow.step ? Color.secondary.opacity(0.6) : Color.primary.opacity(0.12))
                            .frame(width: 18, height: 4)
                    }
                }
                .accessibilityElement().accessibilityLabel("Question \(flow.step + 1) of \(flow.total)")
            }
            if !flow.header.isEmpty {
                Text(flow.header).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.control))
            }
        }
    }

    private func optionRow(_ i: Int, _ o: QuestionRequest.Option, multi: Bool) -> some View {
        let on = flow.picks[flow.step].contains(i)
        return Button { flow.pick(i); focus = .card } label: {
            HStack(alignment: .top, spacing: 10) {
                if multi {
                    Image(systemName: on ? "checkmark.square.fill" : "square").font(.body)
                        .foregroundStyle(on ? Color.accentColor : Color.secondary).frame(width: 22, height: 22)
                } else {
                    KeyBadge(text: "\(i + 1)", on: on)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(o.label).fontWeight(.semibold)
                        if o.recommended {
                            Text("Recommended").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.control))
                        }
                    }
                    if !o.detail.isEmpty { Text(o.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                .font(.callout)
                Spacer(minLength: 8)
                if !multi, on { Image(systemName: "checkmark").font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: on ? 1.5 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityLabel(o.recommended ? "\(o.label), recommended" : o.label)
    }

    private func otherRow(_ q: QuestionRequest.Question) -> some View {
        let on = !flow.other[flow.step].trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 10) {
            KeyBadge(text: q.multiSelect ? "+" : "\(flow.otherKey)", on: false, outline: true)
            OtherField(text: Binding(get: { flow.other[flow.step] }, set: { flow.setOther($0) }),
                       placeholder: "Other: type your own answer",
                       onSubmit: { returnKey() }, onEscape: { focus = .card })
                .focused($focus, equals: .other)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: on ? 1.5 : 0.5))
        }
        .padding(.horizontal, 12)
        .id(flow.step)   // a fresh field per question
    }

    private func foot(_ q: QuestionRequest.Question) -> some View {
        HStack(spacing: 8) {
            if flow.step > 0 { Button("Back") { flow.back(); focus = .card } }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else if !canSend {
                HStack(spacing: 4) {
                    Text("Answer in the terminal")
                    KbdGroup(caps: ["⌃", "`"])
                    Text(": Desk cannot send this answer.").lineLimit(2)
                }
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small) }
            hint(q).layoutPriority(-1)
            Button(flow.isLast ? (flow.total > 1 ? "Send Answers" : "Send") : "Next") { returnKey() }
                .buttonStyle(.borderedProminent)
                .disabled(busy || !flow.valid || (flow.isLast && !canSend))
        }
        .controlSize(.regular)
    }

    /// Key hints as keycaps: "1 – 3 choose · ↩ next".
    private func hint(_ q: QuestionRequest.Question) -> some View {
        HStack(spacing: 6) {
            KbdGroup(caps: q.options.count > 1 ? ["1", "–", "\(q.options.count)"] : ["1"])
            Text(q.multiSelect ? "toggle" : "choose")
            KbdGroup(caps: ["↩"])
            Text(flow.isLast ? "send" : "next")
        }
        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func returnKey() {
        focus = .card
        guard !busy else { return }
        if flow.needsLoad, flow.valid {
            // The user goes on past the questions read so far: read the rest now (this moves the picker and back).
            busy = true; problem = nil
            Task {
                defer { busy = false }
                do {
                    if let all = try await onLoadAll(), all.questions.count > flow.questions.count {
                        QuestionProbe.report?(.loaded(all.questions.count))
                        flow.load(all.questions); _ = flow.advance()
                    } else { problem = "Could not read the next question. Answer in the terminal."; QuestionProbe.report?(.failed(problem ?? "")) }
                } catch { problem = Self.problemText(error); QuestionProbe.report?(.failed(problem ?? "")) }
            }
            return
        }
        guard flow.advance(), canSend else { return }
        busy = true; problem = nil
        Task {
            defer { busy = false }
            do { try await onSend(flow.values()); sent = true; QuestionProbe.report?(.sent) }
            catch { problem = Self.problemText(error); QuestionProbe.report?(.failed(problem ?? "")) }
        }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
        switch press.key {
        case .return: returnKey(); return .handled
        case .escape:
            if flow.step > 0 { flow.back(); return .handled }
            return .ignored
        default:
            guard let n = Int(press.characters), (1...9).contains(n) else { return .ignored }
            switch flow.digit(n) {
            case .picked: return .handled
            case .other: focus = .other; return .handled
            case .ignored: return .ignored
            }
        }
    }
}

private struct KeyBadge: View {
    let text: String
    var on = false
    var outline = false
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(on ? Color.white : Color.secondary)
            .frame(width: 22, height: 22)
            .background(on ? Color.accentColor : outline ? Color.clear : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay { if outline { RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Color.primary.opacity(0.15)) } }
    }
}

/// "Other" text field. Return while the input method has marked text commits the text and never sends; Esc leaves.
struct OtherField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var onSubmit: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false; f.drawsBackground = false; f.focusRingType = .none
        f.font = .systemFont(ofSize: NSFont.systemFontSize)
        f.placeholderString = placeholder
        f.delegate = context.coordinator
        f.cell?.lineBreakMode = .byTruncatingTail
        f.setAccessibilityLabel("Other answer")
        return f
    }
    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        let editing = (f.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if f.stringValue != text, !editing { f.stringValue = text }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OtherField
        init(_ p: OtherField) { parent = p }
        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField, let tv = f.currentEditor() as? NSTextView, !tv.hasMarkedText() else { return }
            parent.text = f.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                if textView.hasMarkedText() { textView.unmarkText(); parent.text = textView.string; return true }
                parent.text = textView.string
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape(); return true
            default:
                return false
            }
        }
    }
}

/// An answered question in the transcript: each question and its answer, then a check line.
struct QuestionAnsweredRow: View {
    let model: QuestionRequest
    var time: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.state {
            case .answered(let answers):
                ForEach(Array(model.questions.enumerated()), id: \.offset) { k, q in
                    let a = answers.flatMap { $0.indices.contains(k) ? $0[k] : nil }
                    row(q.text, a.map { $0.isEmpty ? "Skipped" : QuestionText.shown($0) })
                }
                meta("checkmark.circle.fill", .green, "Answered")
            case .declined:
                ForEach(Array(model.questions.enumerated()), id: \.offset) { _, q in row(q.text, nil) }
                meta("xmark.circle.fill", .secondary, "Declined")
            case .pending:
                EmptyView()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
    }

    private func row(_ q: String, _ a: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(q).foregroundStyle(.secondary)
            if let a { Text("\(Text("→").foregroundStyle(.tertiary)) \(Text(a).fontWeight(.semibold))") }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func meta(_ symbol: String, _ tint: Color, _ word: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(time.map { "\(word) at \($0.formatted(date: .omitted, time: .shortened))" } ?? word)
        }
        .font(.caption).foregroundStyle(.tertiary)
    }
}
