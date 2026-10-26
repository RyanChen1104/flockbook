# Tab-overflow CI follow-up

Baseline: `b1557bb`; maintenance branch before this change: `63f24d7`.
[CI run 40282379616](https://github.com/minchenlee/flockbook/actions/runs/40282379616)
failed the last-tab check for 40 tabs, 1600 pt width, sidebar hidden, full-screen
layout. The island was correctly placed at x 152...1408, but the selected pill
remained at x 5527...5687. Other island, toolbar, action and sidebar bounds passed.

## Native sidebar completion investigation

The overflow fixture never calls `AppModel.toggleSidebar()`. It only assigns
visibility through `setSidebarVisibility`, changes the full-screen layout flag,
and selects tabs/workspaces. Each UI check runs in a separate app process, so a
completion from a preceding chrome or sidebar check cannot survive into it.

Temporary tracing at the entry and completion of the native toggle recorded zero
requests and zero completions throughout the controlled full overflow check.
Both baseline and branch controls reproduce the failure without entering that
path. A positive tracing control using the existing root-width check passes and
records eight native toggle requests and eight completions, confirming that the
zero-event overflow trace is meaningful. The exact instrumented sources and raw
logs are retained with the local evidence; the temporary AppModel instrumentation is not included in this change.

The completion added in `7cdb677` captures a generation, not the old visibility.
It checks that generation before writing, then reads the current native sidebar
state. An explicit visibility request increments the generation first. No pending
completion is created by the overflow fixture's setter calls. This evidence
excludes that completion as the cause of the reported test failure; no change to
its animation or synchronization is made here.

## Normal revision comparison

| Revision | Passed | Failed | Skipped / retried |
| --- | ---: | ---: | ---: |
| `b1557bb` | 10/10 | 0 | 0 / 0 |
| `63f24d7` before this fix | 8/10 | 2 | 0 / 0 |

Branch repetition 6 finished with five last-tab failures. Repetition 9 already
had five last-tab failures before the 180 second runner limit terminated it.
Neither is silently retried or excluded. The normal batches ran under varying
host load, including a build and temporary slot pauses for disk pressure, so
these small samples alone do not establish a causal regression. Historical
0/77 incidence does not rule out the scheduling race reproduced below.

## Red/green observation evidence

The selected-tab task normally debounces for 200 ms, and the old check sampled
its geometry after a fixed 1.2 seconds. A delayed task can still be pending when
the check reads the offscreen pill and selects another tab for its next phase,
canceling the pending task. The controlled failure is a sample taken before the selection operation completes,
not proof that the island is misplaced. It demonstrates a pre-existing race that
produces the CI signature; the failed CI runner has no scheduling trace to prove
its precise delay.

Both revisions were built with the same controlled 2000 ms selection-task delay.
The original full overflow check failed all 24 last-tab assertions on each
revision, including the same 40-tab / 1600 pt / sidebar-off full-screen case.
No sidebar toggle or completion was invoked in either control.

The revised observer retains the original observation interval, then waits for
the selected pill's actual geometry to fit inside the island, up to a total
five-second deadline. The original 0.5 pt tolerance and all toolbar, overflow,
island and full-screen assertions remain. It does not scroll on behalf of the
app. The completed test window's content is detached before moving to the next
window so old view probes cannot overwrite the next fixture.

With the same 2000 ms delay, the complete fixed check passes all 24 last-tab
assertions. Its trace records the app issuing its own scroll and the pill entering
the island in 2.107–2.322 seconds (median 2.212 seconds). A missing completion
still fails at the deadline.
The production debounce remains 200 ms; delay and trace options are initialized
only by the offscreen overflow check.

## Validation

Local host: macOS 26.1. All runs use offscreen windows, independent output
directories, and frozen binaries/runners. Full-screen checks use the existing
layout emulation; no visible window or real full-screen acceptance is claimed.
Retries and skipped items are not counted as passes.

The source gate was rerun after reclaiming regenerable compiler outputs:
`disk-guard 5` passed, `swift build` printed `Build complete! (198.26s)`, and
`swift run HerdrKitChecks` printed `OK 2281 checks passed` (exit 0).
No source changed after that build. No push, merge, workflow change or remote CI
rerun was performed.

Final fresh-process results on the fixed candidate:

| Check | Passed | Failed | Skipped / retried |
| --- | ---: | ---: | ---: |
| chrome | 10/10 | 0 | 0 / 0 |
| sidebar | 10/10 | 0 | 0 / 0 |
| root-width | 10/10 | 0 | 0 / 0 |
| tab-overflow | 10/10 | 0 | 0 / 0 |

The source patch matches the frozen candidate used throughout these batches.
The separate two-second-delay full overflow check also passed all 24 last-tab
assertions. Local raw logs, controlled sources and frozen binaries are retained
under the ignored build evidence directory (121 MB for this follow-up). Remote
CI and real-window acceptance remain separate from these local results.
