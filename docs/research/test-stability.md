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
