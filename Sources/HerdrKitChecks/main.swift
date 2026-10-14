import Foundation
@testable import HerdrKit

// Fallback test runner: `swift test` runs nothing under Command Line Tools (no XCTest, silent swift-testing helper).
// `swift run HerdrKitChecks` runs the same checks as Tests/HerdrKitTests and exits non-zero on failure.

actor EventCounter {
    var count = 0, error: String?
    func bump() { count += 1 }
    func fail(_ e: String) { error = e }
}

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var total = 0
func check(_ ok: Bool, _ name: String, line: Int = #line) {
    total += 1
    if !ok { failures += 1; print("FAIL \(name) (line \(line))") }
}

// Modes: each one exits when its flag is present.
try await modeWatch()
try await modePerf()
try await modePolishBench()
try await modeBenchLocate()
try await modeBenchMem()
try await modeBenchParse()
try await modeLogSweep()
try await modeAgentsLive()
try await modeBenchLog()
try await modeTermLive()
try await modeScrollLive()
try await modeWheelLive()
try await modeTabmoveLive()
try await modeQuestionLive()
try await modeWsLive()
try await modeServeWeb()
try await modePaneLive()
try await modeLive()
try await modeSend()
try await modeReady()
try await modeKeys()
try await modeLayout()

// Checks, in the original order.
try await checksSnapshot()
try await checksSession()
try await checksConversation()
try await checksInjected()
try await checksPasted()
try await checksCodexRollout()
try await checksToolCalls()
try await checksLoadEarlier()
try await checksTimestamps()
try await checksTerminalSession()
try await checksPaneLabel()
try await checksScroll()
try await checksFileWatcher()
try await checksPromptDetection()
try await checksLocateTail()
try await checksLoadState()
try await checksStoreTiming()
try await checksCut()
try await checksAskUserQuestion()
try await checksCodexQuestions()
try await checksPi()
try await checksCursor()
try await checksQuestionScreen()
try await checksQuestionKeys()
try await checksSessionFallback()
try await checksApprovalNotice()
try await checksHubProtocol()
try await checksHubSession()
try await checksHubImage()
try await checksHubPairing()
try await checksHubServer()
try await checksHubTLS()
try await checksHubHTTP()
try await checksHubServe()
try await checksHubFuzz()
try await checksHubSecurity()
try await checksHubSecurityReview2()
try await checksHubReview3()
try await checksHubReview4()
try await checksHubReview5()
try await checksHubReview6()
try await checksHubReview7()
try await checksClaudeHook()
try await checksClaudeHookReview1()
try await checksClaudeHookReview2()
try await checksClaudeHookReview3()
try await checksUpdater()
try await checksLaunchGuard()
try await checksConversationWindow()
try await checksFirstRun()
try await checksWebPush()
try await checksPushThrottle()
try await checksPushSender()
try await checksPushStore()
await checksPushCenter()

print(failures == 0 ? "OK \(total) checks passed" : "\(failures) of \(total) checks FAILED")
exit(failures == 0 ? 0 : 1)
