import Foundation
@testable import HerdrKit

/// A workspace's monogram: two letters from its first two words. An apostrophe inside a word (Brandon's, O'Neil,
/// straight or curly) does not split it. The phone's monogram() gets the same cases (scripts/web-test.mjs).
func checksMonogram() {
    let cases: [(String, String)] = [
        ("Brandon's Brain", "BB"), ("Brandon’s Brain", "BB"), ("O'Neil Lab", "OL"), ("O’Neil Lab", "OL"), ("Don't Panic", "DP"),
        ("[ME] Meadow · Migration", "MM"), ("OpenAtlas", "OA"), ("flockbook", "FL"), ("[ME]", "ME"),
    ]
    for (name, want) in cases {
        let got = WorkspaceMonogram.letters(name)
        check(got == want, "monogram: \(name) -> \(want) (\(got))")
    }
}
