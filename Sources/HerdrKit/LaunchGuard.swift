import Foundation

/// The app's flags, and the launch guard that refuses a -- argument it does not know. A flag the app does not match
/// starts a normal launch: a real window, a Dock icon, a focus change. A misspelt flag, or a flag and its value passed as
/// one argument (zsh does not split an unquoted variable), must stop before any of that.
public enum LaunchGuard {
    /// Checks that never show a window, a Dock icon, or take focus (HerdrDeskApp).
    public static let headless: Set<String> = [
        "--headless", "--snapshot", "--snapshot-reading", "--snapshot-live", "--snapshot-demo", "--snapshot-settings",
        "--snapshot-remote", "--stress", "--hittest", "--test-approve", "--test-notice", "--test-hub", "--test-remote",
        "--serve-remote", "--test-terminal", "--test-scroll", "--test-bottom", "--test-table", "--test-closetab",
        "--test-menus", "--test-tabdrag", "--test-chrome", "--test-sheet", "--test-panemenu", "--test-wheel",
        "--test-send-image", "--test-composer", "--fuzz", "--test-sidebar", "--test-sidebar-layout", "--test-root-width",
        "--test-newtab-live", "--test-settings-migration", "--test-island-height", "--test-tabkeys", "--test-update",
        "--test-settings-page",
    ]
    /// Content-area checks (ContentTests), also headless.
    public static let content: Set<String> = [
        "--test-sendfail", "--test-loadstate", "--test-glyph", "--test-panebars", "--test-surfaces", "--test-search",
        "--test-textsize", "--test-scrolltop", "--test-shortcuts", "--test-question", "--test-screencolumn",
        "--test-question-live", "--bench-conversation", "--test-conversation-churn",
    ]
    /// The checks with a real window, run only with the owner's leave.
    public static let realWindow: Set<String> = ["--test-fullscreen-real", "--test-scroll-real"]
    /// Options that change a launch or a check: the session, the look, the preview stores, the fuzz seed, live-check modes.
    public static let options: Set<String> = [
        "--session", "--read-only", "--light", "--dark", "--save-window", "--preview", "--preview-dense", "--seed",
        "--deny", "--image", "--warm", "--other",
    ]
    public static let known: Set<String> = headless.union(content).union(realWindow).union(options)

    /// Nil: launch. Otherwise the usage line to print before exit(2). `known` adds flags to the app's own.
    public static func problem(_ arguments: [String], known extra: Set<String> = []) -> String? {
        for arg in arguments.dropFirst() {
            let flag = arg.hasPrefix("--")
            if flag, arg.contains(where: \.isWhitespace) {
                return usage("“\(arg)” has whitespace in it: pass a flag and its value as separate arguments")
            }
            if flag, !known.contains(arg), !extra.contains(arg) {
                return usage("unknown flag “\(arg)”")
            }
        }
        return nil
    }

    private static func usage(_ what: String) -> String {
        "usage: HerdrDesk [--session <name>] [<flag> [<value>]]: \(what). Nothing was opened."
    }
}
