import Foundation

/// Incremental parser for Claude Code session JSONL. Feed lines in order; read `items`.
public struct ConversationParser: Sendable {
    var done: [ConversationItem] = []
    var run: [(tool: String, label: ToolLabel, id: String)] = []   // open tool run
    var runKey = ""
    var openToolUses: [String: String] = [:]   // tool_use id -> command text, until a result arrives
    var openOrder: [String] = []
    var callTS: [String: Date] = [:]        // tool call id -> time of its line
    var lineTS: Date?                        // time of the line being fed
    var callById: [String: ToolCall] = [:]   // call details; results patch these after the chip was emitted
    var runsByKey: [String: [(tool: String, label: ToolLabel, id: String)]] = [:]
    var questionAt: [String: Int] = [:]      // AskUserQuestion tool_use id -> index in `done`
    var pi = PiState()                               // pi entry tree (see ConversationParser+Pi.swift)

    public init() {}

    struct ToolLabel { var symbol: String; var singular: String; var plural: String? }

    /// True while the newest tool call has no result yet. Also true while the tool runs, so it is not proof of a prompt.
    public var hasOpenToolUse: Bool { !openOrder.isEmpty }

    /// Items so far. The newest tool call without a result is emitted as a `pending` permissionRequest
    /// (replacing its chip); once the result arrives it goes back into the chips.
    public func items() -> [ConversationItem] {
        var out = done.map { item -> ConversationItem in
            guard item.id.hasPrefix("tools-"), let r = runsByKey[String(item.id.dropFirst(6))] else { return item }
            return Self.chips(r, key: String(item.id.dropFirst(6)), calls: callById, at: r.first.flatMap { callTS[$0.id] })
        }
        var run = self.run
        var perm: ConversationItem?
        if let last = openOrder.last, let cmd = openToolUses[last], let i = run.lastIndex(where: { $0.id == last }) {
            let t = run.remove(at: i)
            perm = ConversationItem(id: "perm-\(last)", kind: .permissionRequest(
                PermissionRequest(title: "Wants to \(Self.verb(t.tool))", command: cmd, toolName: t.tool, toolUseId: last, state: .pending)), timestamp: callTS[last])
        }
        if !run.isEmpty { out.append(Self.chips(run, key: runKey, calls: callById, at: run.first.flatMap { callTS[$0.id] })) }
        if let perm { out.append(perm) }
        return out
    }

    /// `offset`: byte offset of the line in its file. Codex lines have no uuid, so it gives them ids that stay stable when earlier lines are prepended.
    public mutating func feed(line: String, offset: UInt64? = nil) {
        // JSONSerialization returns autoreleased Foundation objects. A background task drains its pool only when the job
        // ends, so a 2 MB parse would hold every line's objects at once; drain per line instead.
        autoreleasepool { feedLine(line, offset: offset) }
    }

    private mutating func feedLine(_ line: String, offset: UInt64?) {
        guard let data = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lineTS = Self.parseTime(o["timestamp"] as? String)
        if let payload = o["payload"] as? [String: Any] { feedCodex(type: o["type"] as? String, payload: payload, offset: offset); return }
        if o["uuid"] == nil, let t = o["type"] as? String, Self.piTypes.contains(t) { feedPi(o, line: line); return }
        if Self.isCursor(o) { feedCursor(o, offset: offset); return }
        if o["isSidechain"] as? Bool == true { return }
        let type = o["type"] as? String
        guard type == "user" || type == "assistant",
              let msg = o["message"] as? [String: Any] else { return }
        let uuid = o["uuid"] as? String ?? UUID().uuidString
        let meta = o["isMeta"] as? Bool ?? false
        let compactFlag = o["isCompactSummary"] as? Bool ?? false

        var blocks: [[String: Any]] = []
        if let s = msg["content"] as? String { blocks = [["type": "text", "text": s]] }
        else if let a = msg["content"] as? [[String: Any]] { blocks = a }

        for (i, b) in blocks.enumerated() {
            let bid = "\(uuid)-\(i)"
            switch b["type"] as? String {
            case "text":
                let text = (b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                if type == "user" {
                    if compactFlag || text.hasPrefix("This session is being continued") {
                        flush()
                        done.append(ConversationItem(id: bid, kind: .status("Context compacted"), timestamp: lineTS))
                        continue
                    }
                    if meta || Self.isInjected(text) { continue }
                    flush()
                    done.append(ConversationItem(id: bid, kind: .userText(text), timestamp: lineTS))
                } else {
                    flush()
                    done.append(ConversationItem(id: bid, kind: .assistantText(text), timestamp: lineTS))
                }
            case "tool_use":
                guard type == "assistant" else { continue }
                let name = b["name"] as? String ?? "tool"
                let input = b["input"] as? [String: Any] ?? [:]
                let id = b["id"] as? String ?? bid
                if name == "AskUserQuestion", let q = QuestionAdapter.claude(id: id, input: input) {   // a question card, never a permission
                    flush()
                    questionAt[id] = done.count
                    done.append(ConversationItem(id: "q-\(id)", kind: .question(q), timestamp: lineTS))
                    continue
                }
                if run.isEmpty { runKey = bid }
                run.append((name, Self.label(for: name), id))
                callTS[id] = lineTS
                openToolUses[id] = Self.commandText(name: name, input: input)
                openOrder.append(id)
                callById[id] = ToolCall(id: id, toolName: name, summary: Self.summary(name: name, input: input),
                                        input: Self.cut(Self.prettyJSON(input)))
            case "tool_result":
                if let id = b["tool_use_id"] as? String, let at = questionAt[id], case .question(var q) = done[at].kind {
                    q.state = QuestionAdapter.claudeState(q, isError: b["is_error"] as? Bool ?? false,
                                                 result: o["toolUseResult"], text: Self.resultText(b["content"]))
                    done[at].kind = .question(q)
                    questionAt[id] = nil
                } else if let id = b["tool_use_id"] as? String {
                    callById[id]?.output = Self.cut(Self.resultText(b["content"]))
                    callById[id]?.isError = b["is_error"] as? Bool ?? false
                    openToolUses[id] = nil
                    openOrder.removeAll { $0 == id }
                }
            default: break
            }
        }
    }

    // MARK: Codex rollout lines (`~/.codex/sessions/**/rollout-*.jsonl`)

    var codexSeq = 0

    private mutating func feedCodex(type: String?, payload: [String: Any], offset: UInt64?) {
        guard type == "response_item" else { return }
        codexSeq += 1
        let bid = offset.map { "cx@\($0)" } ?? "cx\(codexSeq)"
        switch payload["type"] as? String {
        case "message":
            let role = payload["role"] as? String
            guard role == "user" || role == "assistant" else { return }
            let parts = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return }
            flush()
            if role == "user" {
                if Self.isInjected(text) || text.hasPrefix("# AGENTS.md") { return }
                answerAsyncQuestions()
                done.append(ConversationItem(id: bid, kind: .userText(text), timestamp: lineTS))
            } else {
                done.append(ConversationItem(id: bid, kind: .assistantText(text), timestamp: lineTS))
            }
        case "custom_tool_call", "function_call", "local_shell_call":
            let name = payload["name"] as? String ?? (payload["type"] as? String == "local_shell_call" ? "shell" : "tool")
            let id = payload["call_id"] as? String ?? bid
            if let q = QuestionAdapter.codex(name: name, callId: id, arguments: payload["arguments"] as? String ?? "") {
                flush()
                questionAt[id] = done.count
                done.append(ConversationItem(id: "q-\(id)", kind: .question(q), timestamp: lineTS))
                return
            }
            if run.isEmpty { runKey = bid }
            run.append((name, Self.codexLabel(for: name), id))
            callTS[id] = lineTS
            openToolUses[id] = Self.codexCommand(payload)
            openOrder.append(id)
            let raw = (payload["arguments"] as? String) ?? (payload["input"] as? String) ?? ""
            callById[id] = ToolCall(id: id, toolName: name, summary: Self.codexCommand(payload), input: Self.cut(raw))
        case "custom_tool_call_output", "function_call_output", "local_shell_call_output":
            if let id = payload["call_id"] as? String, let at = questionAt[id], case .question(var q) = done[at].kind {
                if let state = QuestionAdapter.codexState(q, output: Self.resultText(payload["output"])) {
                    q.state = state; done[at].kind = .question(q)
                }
                if q.state != .pending || q.delivery == .picker { questionAt[id] = nil }
                return
            }
            if let id = payload["call_id"] as? String {
                callById[id]?.output = Self.cut(Self.resultText(payload["output"]))
                openToolUses[id] = nil
                openOrder.removeAll { $0 == id }
            }
        default: break
        }
    }

    /// A user message answers every open `request_user_input_async` question (its answer is free text).
    private mutating func answerAsyncQuestions() {
        for (id, at) in questionAt {
            guard case .question(var q) = done[at].kind, q.delivery == .message else { continue }
            q.state = .answered(nil); done[at].kind = .question(q); questionAt[id] = nil
        }
    }

    static func codexLabel(for tool: String) -> ToolLabel {
        switch tool {
        case "exec", "exec_command", "shell", "local_shell", "container.exec", "write_stdin":
            return ToolLabel(symbol: "terminal", singular: "Ran a command", plural: "Ran %d commands")
        case "apply_patch":
            return ToolLabel(symbol: "pencil", singular: "Edited files", plural: "Edited files %d times")
        case "web_search", "web.run":
            return ToolLabel(symbol: "globe", singular: "Searched the web", plural: "Searched the web %d times")
        case "update_plan":
            return ToolLabel(symbol: "checklist", singular: "Updated the plan", plural: nil)
        default:
            return ToolLabel(symbol: "wrench", singular: "Used \(tool)", plural: nil)
        }
    }

    static func codexCommand(_ payload: [String: Any]) -> String {
        if let args = payload["arguments"] as? String,
           let d = args.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for k in ["cmd", "command"] {
                if let s = o[k] as? String, !s.isEmpty { return s }
                if let a = o[k] as? [String], !a.isEmpty { return a.joined(separator: " ") }
            }
        }
        if let input = payload["input"] as? String, !input.isEmpty {
            return String(input.split(separator: "\n").first ?? "").prefix(200).description
        }
        return payload["name"] as? String ?? "tool"
    }

    mutating func flush() {
        guard !run.isEmpty else { return }
        runsByKey[runKey] = run
        done.append(Self.chips(run, key: runKey, calls: callById, at: run.first.flatMap { callTS[$0.id] }))
        run = []
    }

    // MARK: helpers

    /// ISO 8601 with or without fractional seconds (`2026-10-09T01:02:03.456Z`).
    static func parseTime(_ s: String?) -> Date? {
        guard let s else { return nil }
        return (try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(s, strategy: Date.ISO8601FormatStyle()))
    }

    private static func chips(_ run: [(tool: String, label: ToolLabel, id: String)], key: String, calls: [String: ToolCall], at: Date? = nil) -> ConversationItem {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var labels: [String: ToolLabel] = [:]
        var groups: [String: [ToolCall]] = [:]
        for r in run {
            let k = r.label.singular
            if counts[k] == nil { order.append(k); labels[k] = r.label }
            counts[k, default: 0] += 1
            if let c = calls[r.id] { groups[k, default: []].append(c) }
        }
        let chips = order.map { k -> ToolChip in
            let l = labels[k]!, n = counts[k]!
            let text = (n > 1 ? l.plural.map { String(format: $0, n) } : nil) ?? l.singular
            return ToolChip(symbol: l.symbol, text: text, calls: groups[k] ?? [], id: Self.stableUUID("\(key)|\(k)"))
        }
        return ConversationItem(id: "tools-\(key)", kind: .toolChips(chips), timestamp: at)
    }

    static func label(for tool: String) -> ToolLabel {
        switch tool {
        case "Read": return ToolLabel(symbol: "doc.text", singular: "Read a file", plural: "Read %d files")
        case "Edit", "MultiEdit", "NotebookEdit": return ToolLabel(symbol: "pencil", singular: "Edited a file", plural: "Edited %d files")
        case "Write": return ToolLabel(symbol: "square.and.pencil", singular: "Wrote a file", plural: "Wrote %d files")
        case "Bash", "BashOutput", "Monitor": return ToolLabel(symbol: "terminal", singular: "Ran a command", plural: "Ran %d commands")
        case "Grep", "Glob": return ToolLabel(symbol: "magnifyingglass", singular: "Searched the code", plural: "Searched the code %d times")
        case "WebFetch", "WebSearch": return ToolLabel(symbol: "globe", singular: "Searched the web", plural: "Searched the web %d times")
        case "Agent", "Task": return ToolLabel(symbol: "person.2", singular: "Delegated a task", plural: "Delegated %d tasks")
        case "TodoWrite": return ToolLabel(symbol: "checklist", singular: "Updated the to-do list", plural: nil)
        default:
            if tool.hasPrefix("mcp__") { return ToolLabel(symbol: "puzzlepiece.extension", singular: "Used a connector", plural: "Used connectors %d times") }
            return ToolLabel(symbol: "wrench", singular: "Used \(tool)", plural: nil)
        }
    }

    static func verb(_ tool: String) -> String {
        switch tool {
        case "Bash": "run a command"
        case "Edit", "MultiEdit", "NotebookEdit": "edit a file"
        case "Write": "write a file"
        case "Read": "read a file"
        case "WebFetch", "WebSearch": "use the web"
        default: "use \(tool)"
        }
    }

    /// Same text, same UUID: chip identity must not change on every `items()` call, or the UI diffs every row each time.
    static func stableUUID(_ s: String) -> UUID {
        var a: UInt64 = 0xcbf29ce484222325, b: UInt64 = 0x84222325cbf29ce4
        for u in s.utf8 { a = (a ^ UInt64(u)) &* 0x100000001b3; b = (b &+ UInt64(u)) &* 0x100000001b3 ^ a }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: a >> (8 * UInt64(i))); bytes[8 + i] = UInt8(truncatingIfNeeded: b >> (8 * UInt64(i))) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static let maxDetail = 4096

    /// Cuts to 4 KB of UTF-8 on a character boundary and appends "…".
    static func cut(_ s: String) -> String {
        guard s.utf8.count > maxDetail else { return s }
        // Step back from byte 4096 to the start of a character (one String per call, not one per character).
        var i = s.utf8.index(s.utf8.startIndex, offsetBy: maxDetail)
        while i > s.startIndex, i.samePosition(in: s) == nil { i = s.utf8.index(before: i) }
        return String(s[..<i]) + "…"
    }

    static func prettyJSON(_ o: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(o),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }

    /// tool_result content: a string, or an array of `{type:text,text}` blocks.
    static func resultText(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let a = v as? [[String: Any]] { return a.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        return ""
    }

    static func summary(name: String, input: [String: Any]) -> String {
        let keys: [String]
        switch name {
        case "Bash": keys = ["command"]
        case "Read", "Write", "Edit", "MultiEdit": keys = ["file_path", "path"]
        case "NotebookEdit": keys = ["notebook_path", "file_path"]
        case "Task", "Agent": keys = ["description", "prompt"]
        default: keys = []
        }
        for k in keys { if let s = input[k] as? String, !s.isEmpty { return s } }
        for k in input.keys.sorted() { if let s = input[k] as? String, !s.isEmpty { return s } }
        return name
    }

    static func commandText(name: String, input: [String: Any]) -> String {
        for k in ["command", "file_path", "path", "url", "query", "pattern", "description"] {
            if let s = input[k] as? String, !s.isEmpty { return s }
        }
        return name
    }

    static func isInjected(_ text: String) -> Bool {
        if text.hasPrefix("<") { return true }          // <system-reminder>, <command-name>, <local-command-*>
        if text.hasPrefix("[Request interrupted") { return true }
        if text.hasPrefix("Caveat:") { return true }
        return false
    }
}
