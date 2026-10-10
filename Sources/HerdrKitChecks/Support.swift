import Foundation
@testable import HerdrKit

// Fixtures and helpers shared by the check files.

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../Tests/HerdrKitTests/Fixtures").standardized
func fixture(_ n: String) -> Data { try! Data(contentsOf: fixtures.appendingPathComponent(n)) }
let lines = String(decoding: fixture("session.jsonl"), as: UTF8.self).split(separator: "\n").map(String.init)

func describe(_ items: [ConversationItem]) -> [String] {
    items.map { i in
        switch i.kind {
        case .userText(let t): "user:\(t)"
        case .assistantText(let t): "asst:\(t)"
        case .toolChips(let c): "chips:" + c.map(\.text).joined(separator: "|")
        case .permissionRequest(let p): "perm:\(p.command)"
        case .question(let q): "q:\(q.questions.map(\.header).joined(separator: "|"))"
        case .status: "status"
        }
    }
}


func tail(path: String, line: String) async {
    var it = SessionLog(sessionId: "abc").items(projectsDir: (path as NSString).deletingLastPathComponent + "/..", pollInterval: .milliseconds(30)).makeAsyncIterator()
    let c0 = await it.next()?.count, c1 = await it.next()?.count
    let fh = try! FileHandle(forWritingTo: URL(fileURLWithPath: path))
    try! fh.seekToEnd(); try! fh.write(contentsOf: Data((line + "\n").utf8)); try! fh.close()
    let c2 = await it.next()?.count
    check([c0, c1, c2] == [0, 1, 2], "tail yields growing lists \([c0, c1, c2])")
}

func chipCalls(_ items: [ConversationItem]) -> [ToolCall] {
    items.flatMap { i -> [ToolCall] in if case .toolChips(let c) = i.kind { return c.flatMap(\.calls) } else { return [] } }
}
let cx = String(decoding: fixture("codex.jsonl"), as: UTF8.self).split(separator: "\n").map(String.init)

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
}
