import Foundation

/// Remote protocol v1: the messages between a hub (the machine that runs herdr) and its clients (the phone PWA, the
/// Mac app in remote mode). Spec: docs/design/remote-protocol.md. Fixtures: Tests/HerdrKitTests/Fixtures/hub/.
/// Wire types only; no listener here. Clients send intent (send, approve, answer), never raw keys.
public enum Hub {
    public static let version = 1
    /// Every client message type. Intent only: there is no type for keys or terminal bytes (`attach` carries image
    /// data, which the hub re-encodes into a file of its own; it never reaches the terminal).
    public static let clientTypes = ["pair", "hello", "watch", "unwatch", "loadEarlier", "send", "attach", "approve", "answer", "ping"]
    public static let hubTypes = ["paired", "welcome", "reply", "snapshot", "status", "conversation", "screen", "prompt", "attached", "pong"]
    /// Finished uploads a `send` may name.
    public static let maxAttachments = 4

    public enum DecodeError: Error, Equatable, Sendable {
        case missingVersion
        case unsupportedVersion(Int)
        /// A client message of this type is refused (`badRequest`); a client skips a hub message of this type.
        case unknownType(String)
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(value)
    }

    public static func decodeClient(_ data: Data) throws -> ClientMessage {
        try checkHeader(data, types: clientTypes)
        return try JSONDecoder().decode(ClientMessage.self, from: data)
    }

    public static func decodeHub(_ data: Data) throws -> HubMessage {
        try checkHeader(data, types: hubTypes)
        return try JSONDecoder().decode(HubMessage.self, from: data)
    }

    private struct Header: Decodable { var v: Int?; var type: String }
    private static func checkHeader(_ data: Data, types: [String]) throws {
        let h = try JSONDecoder().decode(Header.self, from: data)
        guard let v = h.v else { throw DecodeError.missingVersion }
        guard v == version else { throw DecodeError.unsupportedVersion(v) }
        guard types.contains(h.type) else { throw DecodeError.unknownType(h.type) }
    }

    /// The open permission prompt of a pane for a `prompt` push. Its id is `ApprovalNotice.prompt` (the log's pending
    /// call, else the prompt box on screen), the same id the notification buttons and the in-app card use, so an
    /// `approve` from any client is checked by the same rule. Nil: no approval open.
    public static func openApproval(_ s: ApprovalNotice.PaneState, logged: PermissionRequest?) -> HubApproval? {
        guard let id = ApprovalNotice.prompt(s, writes: true) else { return nil }
        let r = logged?.toolUseId == id ? logged : ApprovalNotice.screenRequest(s.screen)
        guard let r else { return nil }
        return HubApproval(id: id, tool: r.toolName, title: r.title, command: r.command, state: .pending)
    }

    public static let maxSendText = 16_000, maxOtherText = 2_000
    /// Why client text may not be typed, or nil. Text goes to a terminal: control characters would be keys (CR submits,
    /// ESC starts a sequence, a bracketed-paste end marker escapes a paste). Newline and tab only; no DEL, no C1.
    public static func inputProblem(_ text: String, limit: Int) -> String? {
        if text.count > limit { return "Text over \(limit) characters." }
        for u in text.unicodeScalars where (u.value < 0x20 && u != "\n" && u != "\t") || (0x7f...0x9f).contains(u.value) {
            return "Text with control character U+\(String(format: "%04X", u.value))."
        }
        return nil
    }

    /// A permission prompt the box parser cannot read (a new layout, options scrolled off): the marker line on a
    /// blocked agent's screen, or followed by a numbered option. Counted as open, so nothing is typed into it.
    public static func unreadablePrompt(screen: String, blocked: Bool) -> Bool {
        let lines = screen.components(separatedBy: "\n")
        guard let at = lines.lastIndex(where: { $0.contains(PermissionGate.promptMarker) }) else { return false }
        if blocked { return true }
        return lines[(at + 1)...].prefix(4).contains { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "❯", with: "").trimmingCharacters(in: .whitespaces).hasPrefix("1.") }
    }

    /// The screen shows something typed text would answer as a choice: a permission prompt (read or not), a Claude
    /// or Codex question picker (with its notes view), or any picker with its key line near the bottom ("Enter to
    /// confirm", "Esc to cancel", "enter to submit", "enter continue"), such as Claude's setup and folder-trust
    /// pickers and Codex's trust picker.
    /// The id the hub gives a question. A log question keeps its call id. A Claude screen question ("screen-…",
    /// built from the headers only) also gets a hash of what the card shows: the questions read (text, options,
    /// mode). An answer from a card whose question has changed since is then `stale`, even with the same headers.
    public static func questionID(_ q: QuestionRequest) -> String {
        guard q.toolUseId.hasPrefix("screen-") else { return q.toolUseId }
        let key = ([q.headers.joined(separator: "\u{1f}")] + q.questions.map { k in
            ([QuestionAdapter.flat(k.text), k.multiSelect ? "multi" : "one"] + k.options.map { QuestionAdapter.flat($0.label) }).joined(separator: "\u{1f}")
        }).joined(separator: "\u{1e}")
        let hash = key.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }   // FNV-1a, stable across runs
        return q.toolUseId + "-" + String(hash, radix: 16)
    }

    public static func screenTakesKeys(_ screen: String) -> Bool {
        if ApprovalNotice.screenBox(screen) != nil || QuestionAdapter.claudeScreen(screen) != nil
            || QuestionAdapter.pickerRegion(agent: "codex", screen: screen) != nil
            || QuestionAdapter.pickerRegion(agent: "claude", screen: screen) != nil
            || unreadablePrompt(screen: screen, blocked: false) { return true }
        let lines = screen.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(12)
        let keyLines = ["enter to confirm", "esc to cancel", "enter to submit", "enter to select", "enter continue"]
        guard let keys = lines.lastIndex(where: { l in keyLines.contains { l.lowercased().hasPrefix($0) } }) else { return false }
        return lines[..<keys].contains { $0.hasPrefix("1.") || $0.firstMatch(of: /^[❯›]\s*(1\.|\S)/) != nil && $0 != "❯" && $0 != "›" }
    }

    /// ISO 8601 UTC with milliseconds.
    static func time(_ d: Date?) -> String? {
        guard let d else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}

private struct Envelope: Encodable { var v = Hub.version; var type: String; var id: String? }

// MARK: - Client to hub

public struct HubAnswer: Codable, Hashable, Sendable {
    public var picks: [Int]
    public var other: String?
    public init(picks: [Int], other: String? = nil) { self.picks = picks; self.other = other }
}

public struct ClientMessage: Codable, Hashable, Sendable {
    public enum Body: Hashable, Sendable {
        /// Before hello, on a new device: the pairing secret (from the QR) or the 6 words, and a device name.
        case pair(secret: String, name: String)
        case hello(token: String, client: String, clientVersion: String)
        case watch(pane: String)
        case unwatch(pane: String)
        case loadEarlier(session: String, before: String)
        /// Type the text and submit it, as the composer does. `attachments`: finished `attach` uploads of this
        /// connection; their file paths follow the text.
        case send(pane: String, text: String, attachments: [String] = [])
        /// One part of an image (remote-protocol.md 3.3). `data`: standard base64.
        case attach(upload: String, part: Int, parts: Int, data: String)
        /// `prompt` = the approval id from the last `prompt` push.
        case approve(pane: String, prompt: String, allow: Bool)
        case answer(pane: String, question: String, answers: [HubAnswer])
        case ping

        public var type: String {
            switch self {
            case .pair: "pair"
            case .hello: "hello"
            case .watch: "watch"
            case .unwatch: "unwatch"
            case .loadEarlier: "loadEarlier"
            case .send: "send"
            case .attach: "attach"
            case .approve: "approve"
            case .answer: "answer"
            case .ping: "ping"
            }
        }
    }
    public var id: String
    public var body: Body
    public init(id: String, body: Body) { self.id = id; self.body = body }

    private enum K: String, CodingKey { case v, type, id, secret, name, token, client, clientVersion, pane, session, before, text, attachments, upload, part, parts, data, prompt, allow, question, answers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        let s = { (k: K) in try c.decode(String.self, forKey: k) }
        switch try c.decode(String.self, forKey: .type) {
        case "pair": body = .pair(secret: try s(.secret), name: try s(.name))
        case "hello": body = .hello(token: try s(.token), client: try s(.client), clientVersion: try s(.clientVersion))
        case "watch": body = .watch(pane: try s(.pane))
        case "unwatch": body = .unwatch(pane: try s(.pane))
        case "loadEarlier": body = .loadEarlier(session: try s(.session), before: try s(.before))
        case "send": body = .send(pane: try s(.pane), text: try s(.text), attachments: try c.decodeIfPresent([String].self, forKey: .attachments) ?? [])
        case "attach": body = .attach(upload: try s(.upload), part: try c.decode(Int.self, forKey: .part), parts: try c.decode(Int.self, forKey: .parts), data: try s(.data))
        case "approve": body = .approve(pane: try s(.pane), prompt: try s(.prompt), allow: try c.decode(Bool.self, forKey: .allow))
        case "answer": body = .answer(pane: try s(.pane), question: try s(.question), answers: try c.decode([HubAnswer].self, forKey: .answers))
        case "ping": body = .ping
        case let t: throw Hub.DecodeError.unknownType(t)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(Hub.version, forKey: .v)
        try c.encode(body.type, forKey: .type)
        try c.encode(id, forKey: .id)
        switch body {
        case .pair(let secret, let name):
            try c.encode(secret, forKey: .secret); try c.encode(name, forKey: .name)
        case .hello(let token, let client, let version):
            try c.encode(token, forKey: .token); try c.encode(client, forKey: .client); try c.encode(version, forKey: .clientVersion)
        case .watch(let pane), .unwatch(let pane):
            try c.encode(pane, forKey: .pane)
        case .loadEarlier(let session, let before):
            try c.encode(session, forKey: .session); try c.encode(before, forKey: .before)
        case .send(let pane, let text, let attachments):
            try c.encode(pane, forKey: .pane); try c.encode(text, forKey: .text)
            if !attachments.isEmpty { try c.encode(attachments, forKey: .attachments) }
        case .attach(let upload, let part, let parts, let data):
            try c.encode(upload, forKey: .upload); try c.encode(part, forKey: .part); try c.encode(parts, forKey: .parts); try c.encode(data, forKey: .data)
        case .approve(let pane, let prompt, let allow):
            try c.encode(pane, forKey: .pane); try c.encode(prompt, forKey: .prompt); try c.encode(allow, forKey: .allow)
        case .answer(let pane, let question, let answers):
            try c.encode(pane, forKey: .pane); try c.encode(question, forKey: .question); try c.encode(answers, forKey: .answers)
        case .ping:
            break
        }
    }
}

// MARK: - Hub to client

public enum HubLevel: String, Codable, Hashable, Sendable { case read, input }

public struct HubPaired: Codable, Hashable, Sendable {
    public var token: String
    public var device: HubDevice
    public init(token: String, device: HubDevice) { self.token = token; self.device = device }
}

public struct HubWelcome: Codable, Hashable, Sendable {
    public var hub: String
    public var hubVersion: String
    public var level: HubLevel
    /// herdr session name; nil = the default session.
    public var session: String?
    public init(hub: String, hubVersion: String, level: HubLevel, session: String? = nil) {
        self.hub = hub; self.hubVersion = hubVersion; self.level = level; self.session = session
    }
}

public struct HubError: Codable, Hashable, Sendable {
    public enum Code: String, Codable, Hashable, Sendable { case unauthorized, readOnly, stale, promptOpen, notFound, badRequest, rateLimited, unsupportedVersion, failed }
    public var code: Code
    public var message: String
    public init(code: Code, message: String) { self.code = code; self.message = message }
}

public struct HubReply: Codable, Hashable, Sendable {
    public var re: String
    public var ok: Bool
    public var error: HubError?
    public init(re: String, ok: Bool, error: HubError? = nil) { self.re = re; self.ok = ok; self.error = error }
}

public struct HubConversation: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Hashable, Sendable { case replace, append, prepend }
    public var pane: String
    public var session: String
    public var mode: Mode
    public var items: [HubItem]
    public var hasEarlier: Bool
    public init(pane: String, session: String, mode: Mode, items: [HubItem], hasEarlier: Bool) {
        self.pane = pane; self.session = session; self.mode = mode; self.items = items; self.hasEarlier = hasEarlier
    }
}

/// The open prompt of a watched pane. Both nil: none open.
public struct HubPrompt: Codable, Hashable, Sendable {
    public var pane: String
    public var approval: HubApproval?
    public var question: HubQuestion?
    public init(pane: String, approval: HubApproval? = nil, question: HubQuestion? = nil) { self.pane = pane; self.approval = approval; self.question = question }
}

/// The last `attach` part was taken: the re-encoded image's size.
public struct HubAttached: Codable, Hashable, Sendable {
    public var upload: String
    public var width: Int, height: Int
    public var bytes: Int
    public init(upload: String, width: Int, height: Int, bytes: Int) { self.upload = upload; self.width = width; self.height = height; self.bytes = bytes }
}

public enum HubMessage: Codable, Hashable, Sendable {
    /// The answer to a good `pair`: the new device token, shown once. The client sends `hello` with it next.
    case paired(HubPaired)
    case welcome(HubWelcome)
    case reply(HubReply)
    case snapshot([HubWorkspace])
    case status(pane: String, status: AgentStatus)
    case conversation(HubConversation)
    case screen(pane: String, text: String)
    case prompt(HubPrompt)
    case attached(HubAttached)
    case pong

    public var type: String {
        switch self {
        case .paired: "paired"
        case .welcome: "welcome"
        case .reply: "reply"
        case .snapshot: "snapshot"
        case .status: "status"
        case .conversation: "conversation"
        case .screen: "screen"
        case .prompt: "prompt"
        case .attached: "attached"
        case .pong: "pong"
        }
    }

    private enum K: String, CodingKey { case v, type, workspaces, pane, status, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .type) {
        case "paired": self = .paired(try HubPaired(from: decoder))
        case "welcome": self = .welcome(try HubWelcome(from: decoder))
        case "reply": self = .reply(try HubReply(from: decoder))
        case "snapshot": self = .snapshot(try c.decode([HubWorkspace].self, forKey: .workspaces))
        case "status": self = .status(pane: try c.decode(String.self, forKey: .pane), status: try c.decode(AgentStatus.self, forKey: .status))
        case "conversation": self = .conversation(try HubConversation(from: decoder))
        case "screen": self = .screen(pane: try c.decode(String.self, forKey: .pane), text: try c.decode(String.self, forKey: .text))
        case "prompt": self = .prompt(try HubPrompt(from: decoder))
        case "attached": self = .attached(try HubAttached(from: decoder))
        case "pong": self = .pong
        case let t: throw Hub.DecodeError.unknownType(t)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .paired(let p): try p.encode(to: encoder)
        case .welcome(let w): try w.encode(to: encoder)
        case .reply(let r): try r.encode(to: encoder)
        case .conversation(let m): try m.encode(to: encoder)
        case .prompt(let p): try p.encode(to: encoder)
        case .attached(let a): try a.encode(to: encoder)
        case .snapshot, .status, .screen, .pong: break
        }
        var c = encoder.container(keyedBy: K.self)
        try c.encode(Hub.version, forKey: .v)
        try c.encode(type, forKey: .type)
        switch self {
        case .snapshot(let ws): try c.encode(ws, forKey: .workspaces)
        case .status(let pane, let status): try c.encode(pane, forKey: .pane); try c.encode(status, forKey: .status)
        case .screen(let pane, let text): try c.encode(pane, forKey: .pane); try c.encode(text, forKey: .text)
        default: break
        }
    }
}

// MARK: - Shared objects

public struct HubAgent: Codable, Hashable, Sendable {
    public var name: String
    public var kind: String
    public var status: AgentStatus
    public var session: String?
    public var title: String
    public init(_ a: Agent) { name = a.name; kind = a.kind; status = a.status; session = a.sessionId; title = a.title }
}

/// A pane without its terminal id (that stays inside the hub).
public struct HubPane: Codable, Hashable, Sendable {
    public var id: String
    public var cwd: String
    public var label: String?
    public var agent: HubAgent?
    public init(_ p: Pane) { id = p.id; cwd = p.cwd; label = p.label; agent = p.agent.map(HubAgent.init) }
}

public struct HubTab: Codable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var number: Int
    public var status: AgentStatus
    public var panes: [HubPane]
    public init(_ t: Tab) { id = t.id; label = t.label; number = t.number; status = t.status; panes = t.panes.map(HubPane.init) }
}

public struct HubWorkspace: Codable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var tabs: [HubTab]
    public init(_ w: Workspace) { id = w.id; label = w.label; tabs = w.tabs.map(HubTab.init) }
}

/// A tool call without its input and output (size; the phone shows the summary).
public struct HubToolCall: Codable, Hashable, Sendable {
    public var id: String
    public var tool: String
    public var summary: String
    public var done: Bool
    public var error: Bool
    public init(id: String, tool: String, summary: String, done: Bool, error: Bool) {
        self.id = id; self.tool = tool; self.summary = summary; self.done = done; self.error = error
    }
    public init(_ c: ToolCall) { self.init(id: c.id, tool: c.toolName, summary: c.summary, done: c.output != nil, error: c.isError) }
}

public struct HubTool: Codable, Hashable, Sendable {
    public var symbol: String
    public var text: String
    public var calls: [HubToolCall]
    public init(_ c: ToolChip) { symbol = c.symbol; text = c.text; calls = c.calls.map(HubToolCall.init) }
}

public struct HubApproval: Codable, Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable { case pending, resolved }
    public var id: String
    public var tool: String
    public var title: String
    public var command: String
    public var state: State
    public init(id: String, tool: String, title: String, command: String, state: State) {
        self.id = id; self.tool = tool; self.title = title; self.command = command; self.state = state
    }
    public init(_ r: PermissionRequest) {
        self.init(id: r.toolUseId, tool: r.toolName, title: r.title, command: r.command, state: r.state == .pending ? .pending : .resolved)
    }
}

public struct HubOption: Codable, Hashable, Sendable {
    public var label: String
    public var detail: String?
    public var recommended: Bool?
    public init(label: String, detail: String? = nil, recommended: Bool? = nil) { self.label = label; self.detail = detail; self.recommended = recommended }
    public init(_ o: QuestionRequest.Option) { self.init(label: o.label, detail: o.detail.isEmpty ? nil : o.detail, recommended: o.recommended ? true : nil) }
}

public struct HubQuestionItem: Codable, Hashable, Sendable {
    public var id: String
    public var header: String
    public var text: String
    public var multiSelect: Bool
    public var options: [HubOption]
    public init(_ q: QuestionRequest.Question) { id = q.id; header = q.header; text = q.text; multiSelect = q.multiSelect; options = q.options.map(HubOption.init) }
}

public struct HubQuestion: Codable, Hashable, Sendable {
    public enum Delivery: String, Codable, Hashable, Sendable { case picker, message }
    public enum State: String, Codable, Hashable, Sendable { case pending, answered, declined }
    public var id: String
    public var agent: String
    public var delivery: Delivery
    public var state: State
    public var headers: [String]
    public var questions: [HubQuestionItem]
    /// One per question when answered and known.
    public var answers: [String]?
    public init(_ q: QuestionRequest) {
        id = Hub.questionID(q); agent = q.agent; delivery = q.delivery == .picker ? .picker : .message
        headers = q.headers; questions = q.questions.map(HubQuestionItem.init)
        switch q.state {
        case .pending: state = .pending
        case .answered(let a): state = .answered; answers = a
        case .declined: state = .declined
        }
    }
}

public struct HubItem: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case user, assistant, tools, approval, question, status }
    public var id: String
    public var kind: Kind
    public var time: String?
    public var text: String?
    public var tools: [HubTool]?
    public var approval: HubApproval?
    public var question: HubQuestion?
    public init(id: String, kind: Kind, time: String? = nil, text: String? = nil, tools: [HubTool]? = nil, approval: HubApproval? = nil, question: HubQuestion? = nil) {
        self.id = id; self.kind = kind; self.time = time; self.text = text; self.tools = tools; self.approval = approval; self.question = question
    }
    public init(_ item: ConversationItem) {
        let t = Hub.time(item.timestamp)
        switch item.kind {
        case .userText(let s): self.init(id: item.id, kind: .user, time: t, text: s)
        case .assistantText(let s): self.init(id: item.id, kind: .assistant, time: t, text: s)
        case .toolChips(let c): self.init(id: item.id, kind: .tools, time: t, tools: c.map(HubTool.init))
        case .permissionRequest(let r): self.init(id: item.id, kind: .approval, time: t, approval: HubApproval(r))
        case .question(let q): self.init(id: item.id, kind: .question, time: t, question: HubQuestion(q))
        case .status(let s): self.init(id: item.id, kind: .status, time: t, text: s)
        }
    }
}

extension HerdrClient {
    /// Right before remote text is typed: a fresh snapshot and screen. True only when the pane still has an agent, it
    /// is not blocked, and nothing on screen would take the text as a choice (`Hub.screenTakesKeys`). Read-only.
    /// With `agent`: the pane must still show that agent (same kind and session), not one that took its place.
    public func readyForText(paneId: String, agent seen: Agent? = nil) async -> Bool {
        guard let ws = try? await snapshot(),
              let agent = ws.flatMap(\.tabs).flatMap(\.panes).first(where: { $0.id == paneId })?.agent, agent.status != .blocked,
              seen.map({ $0.kind == agent.kind && $0.sessionId == agent.sessionId }) ?? true,
              let screen = try? await visibleText(paneId: paneId) else { return false }
        return !Hub.screenTakesKeys(screen)
    }
}
