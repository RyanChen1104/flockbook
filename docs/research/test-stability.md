# UI and browser test stability audit

Baseline: `b1557bb`. Window: 2026-10-12 through 2026-10-26 UTC, collected on
2026-10-26. The Actions API returned 100 runs and 107 attempts. Three canceled
runs had unavailable job logs; 104 attempt logs were available. Rerun logs can
include jobs carried forward from earlier attempts: those are deduplicated by
run, job and original job start time. A check is counted once per job execution,
including a failed first invocation that passed the script's automatic retry.
Historical KNOWN failures count as failed checks here even when they did not
fail the job. These counts are historical incidence, not a controlled local
before/after experiment.

## Historical ranking

| Check | Failed / observed job executions |
| --- | ---: |
| settings-page | 65/114 |
| island-height | 64/114 |
| glyph | 62/114 |
| screencolumn | 62/114 |
| conversation-churn | 25/116 |
| menus | 7/114 |
| question | 5/114 |
| chrome | 3/115 |
| closetab | 2/112 |
| permission | 2/44 |
| scrolltop | 2/112 |
| shortcuts | 2/112 |
| sidebar | 2/112 |
| tabdrag | 2/113 |
| composer | 1/112 |
| dragroute | 1/14 |
| root-width | 1/112 |
| snapshot-settings | 1/113 |
| termtheme | 1/72 |
| pictures | 0/78 |
| tab-overflow | 0/77 |

The first four checks are historical defects already repaired on this baseline
(see `macos266-checks.md`). The verified release composer defect is also already
fixed (see `composer-checks.md`). The largest remaining failure class is churn:
[run 40168389645, attempt 1](https://github.com/minchenlee/flockbook/actions/runs/40168389645/attempts/1)
passed on retry while reporting a delayed anchor correction. The same class is
present in run 40051204853 attempt 1, which must not be lost when inspecting its
successful second attempt. Historical stall failures include 257, 314 and 319 ms;
current CI already reports those timing-only misses separately from correctness.
No performance threshold is relaxed by this work.

## CDP commands

The original `send()` had no deadline or disconnect rejection, and registered a
pending reply after sending the command. Fault injection on the extracted old
logic failed all four checks: missing reply, synchronous reply, disconnect, and
protocol error context.

The sender now registers before send, bounds each command at 15 seconds, includes
its method and session in errors, clears timers and pending entries, and fails
pending commands on disconnect. A timeout aborts the transport, so polling and
cleanup cannot issue a series of new commands against an unresponsive browser.
Polling propagates fatal transport errors rather than hiding them as a missing
DOM condition. Major suites print phase markers before their first operation.

Validation: 20 fresh fault-injection runs (4/4 each), plus 20 fresh headless Chrome
transport runs (2/2 each). Both batches had 0/20 failed runs. The short real-browser
selection is `node scripts/web-test.mjs --only transport`; the full suite remains
the default. These are transport checks, not acceptance of the entire PWA suite.

## Existing rerun artifact fix

`cfde5a1` already removed attempt numbers from both producer and consumer artifact
names. The current workflow uses `kit-macos15-${{ github.run_id }}` and
`app-macos15-${{ github.run_id }}` with overwrite on upload. A failed-job-only rerun
therefore addresses the original build's artifact. No further workflow change is
made; this is static verification, not a newly executed remote rerun.

## Churn anchor placement

A deterministic offscreen fixture moves an intermediate ancestor by 120 pt while
the immediate parent and document retain their frames. The old observer produces
0 pt compensation; observing the full ancestor chain produces 120 pt immediately,
before any delayed fallback can run. Observers are held weakly and removed on
teardown. The full churn drift and delayed-correction assertions are retained.

Focused red/green command:
`HerdrDesk --test-conversation-churn anchor-placement-only`.

## Locked screen results

The runner checks lock state before each item and after it finishes. A locked
screen produces a per-item `SKIP`; checks invalidated by locking during execution
also become `SKIP`. The final summary subtracts skipped items from passed items
and prints their count and names. A later item may run after the screen unlocks.
An unlocked application failure still fails the run.

The old runner failed 3/4 controlled cases. The revised runner passed all four
cases in 20 fresh runs (0/20 failed). Twenty real offscreen `closetab` invocations
on an unlocked screen also passed, with zero skipped items. No real lock or
unlock operation was sent to the user's computer.

## Notice observation

Polling only the final `ConversationProbe.loading` frame can miss a notice that
correctly appeared and disappeared while the observer was delayed. The probe now
retains actual nonzero geometry events. Churn checks that an appearance occurred
in the load interval and was inside the viewport, as a correctness assertion
rather than a CI timing warning. The app's notice lifetime is unchanged.

The controlled delayed observer sees current height 0 but recorded height 28 pt;
the old current-frame predicate would fail. Twenty fresh `earlier-failure`
offscreen checks passed (0/20 failed). The separate native intermediate-anchor
placement check also passed in 20 fresh processes.

The exploratory full churn run still exposed timing misses (264–690 ms) and the
old notice sampling miss. Its runner was also edited while bash was reading it,
invalidating the batch's shell verdict. No completed 20-run full-churn pass is
claimed. Subsequent repetitions use frozen runner and binary copies. Timing
thresholds, blank-viewport checks and frame-drift checks remain intact.

## Held-at-top request handshake

The old observer waited two seconds for `window.__parked` but ignored a failed
wait, then called the missing function. A controlled four-second delivery delay
reproduces `window.__parked is not a function` with that exact old observer.

The new helper first leaves the top so a real scroll event can occur, then waits
for the actual intercepted request to resolve its readiness promise. It settles
layout frames instead of sleeping for a guessed wheel-event duration. Missing
requests still fail through the bounded CDP command. The same helper drives the
full suite's existing held-touch cases.

Validation: 20 normal and 20 four-second-delayed fresh headless runs passed
(0/20 failures in each batch). The focused check uses actual touch input, waits
until the reply completes before checking held rows, then verifies release inserts
them. The old delayed observer failed 1/1. The full default headless suite passed
all 353 checks, including the original heavy-row budget (15 ms measured, 80 ms
limit, CPU throttle 4x). No heavy-row threshold changed.

## Terminal theme capture readiness

[Run 40168389645 attempt 1](https://github.com/minchenlee/flockbook/actions/runs/40168389645/attempts/1)
contains the theme failure (black capture values). The fixed 1.5-second sleep did
not establish that the synthetic terminal had received and displayed its frame.
A frame-only wait with a two-second fixture delay still reproduced a cursor
failure: SwiftTerm queues its display update after feeding the buffer.

The check now waits for both the frame's `colour7` marker and the fixture's final
caret position (zero-based row 2, column 2), then lays out and flushes the window
before capturing. Original colour, cursor and background assertions are unchanged.
A missing frame/display state fails explicitly at a five-second readiness deadline.

Twenty fresh full `termtheme` checks with `TERMTHEME_FRAME_DELAY_MS=2000` passed:
0/20 failed or skipped. The intermediate frame-only version failed 1/1 delayed
runs; the historical CI incidence was 1/72 observed job executions.

## Picture cache and thumbnail lifecycle checks

[NSCache permits automatic eviction](https://developer.apple.com/documentation/foundation/nscache),
so an immediate cache hit is not a reliable correctness requirement under memory
pressure. The cache check now uses its own cache, forces eviction, and verifies
that the same thumbnail size decodes again. It retains stale-ref and fingerprint
checks. The displayed image is read from the actual thumbnail layer rather than
from the cache; readiness and release wait on their respective conditions with a
deadline. The preceding swap window's content is detached so it cannot retain the
same image during the release scenario.

All 20 fresh full `pictures` offscreen checks passed, including loaded=true and
released=true (0/20 failed or skipped). Historical CI had 0/78 picture failures;
the previously reported local rare flake was not independently reproduced here.
This corrects the cache contract and observation assumptions without changing
image loading, cache limits or the thumbnail lifetime in the product.

## Paused stall-meter callbacks

`pause()` recorded the elapsed gap but did not stop timer callbacks inside nested
run loops from counting the check's own work. A controlled paused nested loop
recorded 435 ms with the old meter. The fixed meter records 0 ms while paused and
still records the deliberately blocked unpaused work (336 ms in the focused
combined run). Twenty fresh controlled runs passed.

The control pumps the nested loop for its full interval: processing only one
run-loop source can handle an AppKit event instead of the overdue timer, which
produced a false zero in an intermediate full churn run. The full churn check now
runs both the positive and negative meter controls before its scenarios. No
performance budget was increased.

## Reused anchor probe identity

Frame observation alone is insufficient when SwiftUI reuses a probe that is
already placed and binds it to a different anchor key. The old update path only
assigned the new tracker/key, leaving the measurements stale until a later
notification or fallback. The controlled rebind case moved 80 pt but compensated
0 pt. Binding now refreshes the probe immediately. Twenty fresh native controls
passed both intermediate-ancestor placement (120 pt) and rebound identity (80 pt).
Full churn stress results are recorded separately from these focused controls.

## Native sidebar visibility synchronization

The baseline reproduced both chrome and menu failures: AppKit had expanded the
sidebar while SwiftUI's visibility binding still reported it hidden. A subsequent
toggle could therefore report the preceding native state. The local baseline
group passed root-width and tab-overflow but failed chrome and menus (2/4).

The model now reads the native collapsed state after the toggle animation ends.
A generation guards against an older completion overwriting a later explicit
visibility request. Explicit requests use `setSidebarVisibility`; feedback from
the SwiftUI binding does not invalidate the pending completion. Invalidating on
every binding assignment was tested and rejected because the native toggle's own
feedback canceled its synchronization. The menu check waits for the real pinned
state with a deadline instead of assuming a 600 ms sleep established it.

Twenty-run verification uses a frozen app and runner with automatic retries
disabled. Earlier candidate failures remain in the local evidence and are not
counted as passes for the final candidate.

The final candidate passed 20 complete groups of chrome, menus and root-width:
each check passed 20/20, with zero failures, retries or skipped items. Historical
incidence was chrome 3/115, menus 7/114 and root-width 1/112. Tab-overflow had
0/77 observed CI failures and one full local baseline pass; its reported failure
under load was not independently reproduced, so no tab-overflow fix is claimed.

## Remaining full-churn failure

The frozen candidate failed repetition 16: scrolled-up recorded a 337 ms stall
against the unchanged 250 ms limit. In the busy-core fling the viewport drift was
1 pt, but the delayed fallback still moved it by 1241 pt once (`lateFixes = 1`).
The existing assertion correctly rejected this. The two deterministic placement
fixes and paused-meter control therefore do not establish that the complete churn
flake is resolved. No speculative additional product fix or retry-policy change
is made. The residual placement race and load-sensitive stall remain tracked by
`hg-uichecks-churn-flake` and `hg-ci-churn-flaky`.

All 20 first invocations completed: 18 passed, 2 failed, none retried or skipped.
Repetition 20 measured a 282099 ms stall during scrolled-up. System power logs
confirm clamshell sleep for 284 seconds overlapping that run. This is an
environment-contaminated timing sample, retained as a raw failure rather than
silently discarded. Even excluding it would not meet the zero-failure criterion:
repetition 16 still has both a stall and a late correction. Historical churn
incidence was 25/116 observed job executions; this local batch is 2/20 raw failures
and is not a matched CI comparison or evidence that churn is fixed.

Stall distributions include all 20 completed runs, including both failures. P95
uses the nearest-rank definition; values are milliseconds. The busy-fling
diagnostic's longest step is a separate measure from this stall table.

| Phase | Median | P95 | Maximum | Original limit |
| --- | ---: | ---: | ---: | ---: |
| append | 29.5 | 45 | 64 | 250 |
| depth | 24 | 44 | 44 | 250 |
| composer | 24 | 44 | 64 | 250 |
| width | 27.5 | 46 | 77 | 250 |
| scrolled-up | 39.5 | 337 | 282099 (sleep overlap) | 250 |
| burst | 53 | 67 | 78 | 250 |
| autoload | 44 | 54 | 76 | 90 |
| autoload-cap | 50 | 62 | 67 | 90 |

## Validation summary

Each row is a separate batch of fresh processes. These local results must not be
interpreted as an estimate of the historical CI failure probability.

| Changed check or controlled case | Before | After |
| --- | --- | --- |
| CDP faults | 4/4 cases failed | 20/20 runs passed, four cases each |
| Real CDP transport | unbounded sender | 20/20 passed |
| Ancestor placement / identity rebind | 0 pt compensation instead of 120 / 80 pt | 20/20 native controls passed |
| Paused stall meter | 435 ms falsely included | 20/20 controls passed; unpaused blocking still detected |
| Lock transitions | 3/4 cases failed | 20/20 runs passed, four cases each |
| Real unlocked runner (closetab) | control | 20/20 passed, zero skips |
| Delayed notice observer (earlier-failure) | current frame misses recorded 28 pt notice | 20/20 passed |
| Held-at-top request | delayed old observer failed 1/1 | 20/20 normal and 20/20 four-second-delay passed |
| Terminal theme | frame-only delayed observer failed 1/1 | 20/20 delayed full checks passed |
| Pictures | local rare flake not reproduced | 20/20 full checks passed |
| Chrome / menus / root-width | local baseline group failed chrome and menus | 20/20 complete groups passed |
| Full conversation-churn | historical 25/116 | 18/20 passed; unresolved |

All successful 20-run native batches had zero retries and zero skipped items.
The full default browser suite additionally passed 353 checks. Local evidence is
retained under the ignored build directory (378 MB at the final checkpoint).

## Scope and remaining validation

All local native runs use offscreen windows; browser runs use headless Chrome.
They do not establish real-window behavior or acceptance on a remote macOS 15
runner. Full churn includes its existing synthetic main-thread blocking and
busy-core fling cases, but no claim is made about every possible host load.
The 250 ms general stall, 90 ms local autoload and 80 ms browser heavy-row limits
are unchanged. The baseline's CI-only timing-warning policy is also unchanged;
correctness assertions, including notice appearance, still fail explicitly.

The artifact rerun repair predates this branch and was verified statically only.
The orchestration owner still needs to exercise a failed-job-only rerun remotely.
Root-width has 20 local passes after the native sidebar fix; the separate
tab-overflow load report remains open because it was not reproduced
(`hg-uichecks-rootwidth-taboverflow`). Remaining remote churn/load acceptance is
tracked by `hg-ci-churn-flaky`.

Final source gate: `disk-guard 5` reported sufficient free space, `swift build`
printed `Build complete! (5.18s)`, and `swift run HerdrKitChecks` printed
`OK 2281 checks passed` (exit 0). The full default browser suite separately
printed `OK 353 checks passed`. No workflow dispatch, push or merge was performed.


## Root-width CI follow-up

[Run 40277928912](https://github.com/minchenlee/flockbook/actions/runs/40277928912)
failed the 1200 pt full-screen slide check. All four root samples were zero and
the panel samples moved right (`-250, -33`). Those values satisfy the root and
monotonicity assertions; the remaining assertion compared the last sampled panel
position against a newer geometry value after the sampling task resumed.

The original loop checked its 0.6 second deadline before sampling. If its last
sleep resumed after that deadline, it skipped the final frame and compared a
mid-animation sample with the now-expanded panel. The same predicate exists on
`b1557bb`, before the native-toggle synchronization in `7cdb677`.

Normal first-invocation comparison, using separate frozen binaries and each
revision's UI runner, passed root-width 10/10 on `b1557bb` and 10/10 on
`fix/test-stability@7da09a8`, without retries or skips. That small sample alone
cannot exclude a regression. An identical controlled 800 ms observer suspension
then failed all four slide cases on each revision: root x remained zero and the
recorded panel positions were monotonic. This reproduces the stale-final-sample
failure independently of `7cdb677`; that product fix is retained.

The observer now always samples after resuming, observes at least the original
0.6 seconds, and requires the actual native sidebar to be expanded with both the
panel and detail at the previously verified shown positions. A five-second
readiness deadline fails a sidebar that never finishes. Root-position and
monotonic-motion assertions remain unchanged. This replaces the comparison with
an unsampled frame; it does not loosen the geometric tolerance or change the
sidebar animation or visibility synchronization.


After the fix, the same 800 ms delayed observer passed all four slide cases,
recording panel positions `-250, 8`, root x zero, and a verified shown endpoint.
The required fresh-process batches completed without retries or skips:

| Check | Passed | Failed |
| --- | ---: | ---: |
| root-width | 10/10 | 0 |
| sidebar | 10/10 | 0 |
| chrome | 9/10 | 1 |

Chrome repetition 8 failed the unchanged `glass Full, windowed` pixel comparison:
sidebar RGB was 0.167/0.167/0.167 while content was 0/0/0. Its native toggle checks
passed, and the subsequent full-screen surface comparison matched at 0.167.
`--test-chrome` does not call the changed root-width observer. This new evidence is
retained as an unresolved capture/surface failure, not retried into a passing
batch or classified as fixed (`hg-chrome-surface-capture-flake`). No cause for that
separate failure is claimed here.

Source gate: `swift build` printed `Build complete! (50.34s)` and
`swift run HerdrKitChecks` printed `OK 2281 checks passed` (exit 0).
The branch remains `fix/test-stability`; no product source, animation behavior,
workflow or release-note behavior changed in this follow-up. No push or remote
CI rerun was performed.
