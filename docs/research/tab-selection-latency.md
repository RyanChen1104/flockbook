# Selected-tab visibility latency

Follow-up to `93773b8`: a five-second correctness deadline does not establish
that selecting a tab is fast. This comparison measures the normal 200 ms
selection debounce on `b1557bb` and the maintenance branch with the same updated
overflow check, rather than treating its former 1.2 second observation sleep as
a latency measurement.

## Measurement

The monotonic clock starts immediately before `model.select`. Geometry callbacks
record the first time the selected pill is fully inside its island with the
existing 0.5 pt tolerance. Frames are separated by model identity and by toolbar
versus full-screen content host. A target already inside at selection is recorded
as zero and flagged separately. The selected task's scroll decision time is also
recorded to distinguish scheduling delay from subsequent placement work.

The check retains its existing observation interval and five-second correctness
deadline. Those waits do not floor the independently recorded geometry time.
Normal-debounce placement above 1200 ms prints a WARN and a GitHub Actions warning
annotation; elapsed time alone does not fail the check. Geometry that never
becomes valid still fails. The warning works without enabling trace output.

Each revision gets ten fresh app processes, each checking the full 24-case matrix
of tab count, width, sidebar visibility and windowed/full-screen layout. Both use
`TAB_OVERFLOW_TRACE=1` and `TAB_OVERFLOW_SCROLL_DELAY_MS=200`, without artificial
main-actor blocking. Baseline/branch order alternates between pairs. The baseline
receives the same checker, timing instrumentation and wait helper; its sidebar
assignment retains the baseline API. Other production changes remain at their
respective revisions.

The intended sample is 240 placements per revision. Median, nearest-rank p95 and
maximum are reported both overall and by case, along with already-visible,
missing, failed and warning counts. Noninitial placements are also summarized so
a difference in already-visible cases cannot hide latency. Raw app logs, JSON
samples, per-run timestamps and host load samples are retained in the ignored
build evidence directory.

These are offscreen geometry-confirmation times on the local host, not
window-server paint times or real full-screen acceptance. Shared host work can
change scheduling; alternating order and per-run load records reduce but do not
eliminate that limitation.

## Warning validation

The runner's new warning integration case fails with the previous runner and
passes with the updated runner; all five runner tests pass. A focused normal
200 ms run under high host load recorded 2409.927 and 1324.845 ms, emitted two CI
warnings, and still passed its geometry checks. An exploratory artificial
main-actor-blocking control exceeded the geometry deadline under the same heavy
host load and failed; it is retained separately and is not a formal comparison
sample.

## Results

The normal-debounce distributions are close; this measurement does not show a
maintenance-branch slowdown. No anchor or sidebar product fix is reverted.

| Revision | Processes / placements | Median (ms) | P95 (ms) | Max (ms) | >1200 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| b1557bb + common checker | 10 / 240 | 450.8 | 590.9 | 770.9 | 0 |
| fix/test-stability + common checker | 10 / 240 | 440.8 | 533.4 | 632.3 | 0 |

All 20 checks passed. There were no missing, censored, already-visible, skipped
or retried samples; all 480 placements use the normal 200 ms debounce. The ten
paired process-median differences (branch minus baseline) have median -4.9 ms,
range -91.7 to +27.7 ms. Across the 24 cases, median differences range from
-51.2 to +11.7 ms. These do not show a consistent increase in the branch.

For the original failing case (40 tabs / 1600 pt / sidebar off / full screen),
baseline median/p95/max are 528.3/618.9/618.9 ms and branch values are
523.1/544.9/544.9 ms, ten samples each.

| Phase | Baseline median / p95 / max (ms) | Branch median / p95 / max (ms) |
| --- | ---: | ---: |
| Select to active-host task decision | 432.6 / 571.9 / 709.0 | 424.9 / 512.4 / 615.5 |
| Scroll decision to geometry confirmation | 16.6 / 32.9 / 88.7 | 16.2 / 33.7 / 131.8 |

The second phase includes scheduling and geometry-report delivery; it is not a
CPU layout profile. Its p95 is essentially unchanged (32.9 versus 33.7 ms),
despite an individual longer branch tail. Shared-host one-minute load medians
were 3.74/3.80, with maxima 18.95/13.56 for baseline/branch. The differing peaks
are a reason not to claim that the branch is intrinsically faster from these
numbers. No sample was removed based on load.

A quieter-host calibration separately confirmed 509.523/565.724 ms at normal
debounce, below the former observer floor. Artificial main-actor delay produced
2135.884/2145.096 ms with WARN and passing geometry. A controlled 2000 ms
debounce passed at 2360.858/2336.128 ms without a normal-budget warning. These
focused controls are not included in the 480 formal samples.

## Per-case distributions

Each row has ten samples per revision. P95 uses nearest rank; for ten samples
it equals the maximum.

| Case | Baseline median / p95 / max (ms) | Branch median / p95 / max (ms) |
| --- | ---: | ---: |
| 20 tabs, 1200 wide, sidebar off full screen | 449.3 / 485.1 / 485.1 | 443.8 / 539.6 / 539.6 |
| 20 tabs, 1200 wide, sidebar off windowed | 290.5 / 406.3 / 406.3 | 295.6 / 301.6 / 301.6 |
| 20 tabs, 1200 wide, sidebar on full screen | 303.0 / 450.4 / 450.4 | 306.9 / 317.0 / 317.0 |
| 20 tabs, 1200 wide, sidebar on windowed | 299.9 / 331.4 / 331.4 | 299.3 / 356.6 / 356.6 |
| 20 tabs, 1600 wide, sidebar off full screen | 437.3 / 551.5 / 551.5 | 433.9 / 466.0 / 466.0 |
| 20 tabs, 1600 wide, sidebar off windowed | 428.0 / 564.8 / 564.8 | 376.8 / 458.9 / 458.9 |
| 20 tabs, 1600 wide, sidebar on full screen | 438.8 / 572.9 / 572.9 | 436.2 / 445.8 / 445.8 |
| 20 tabs, 1600 wide, sidebar on windowed | 428.0 / 524.5 / 524.5 | 427.8 / 451.0 / 451.0 |
| 20 tabs, 2000 wide, sidebar off full screen | 443.6 / 689.4 / 689.4 | 436.2 / 447.6 / 447.6 |
| 20 tabs, 2000 wide, sidebar off windowed | 421.5 / 645.8 / 645.8 | 429.7 / 434.2 / 434.2 |
| 20 tabs, 2000 wide, sidebar on full screen | 440.4 / 514.5 / 514.5 | 437.4 / 472.0 / 472.0 |
| 20 tabs, 2000 wide, sidebar on windowed | 428.8 / 571.6 / 571.6 | 414.9 / 433.3 / 433.3 |
| 40 tabs, 1200 wide, sidebar off full screen | 522.3 / 770.9 / 770.9 | 496.1 / 519.3 / 519.3 |
| 40 tabs, 1200 wide, sidebar off windowed | 501.2 / 533.6 / 533.6 | 496.1 / 533.1 / 533.1 |
| 40 tabs, 1200 wide, sidebar on full screen | 512.4 / 536.4 / 536.4 | 512.5 / 593.2 / 593.2 |
| 40 tabs, 1200 wide, sidebar on windowed | 479.3 / 537.0 / 537.0 | 491.0 / 514.8 / 514.8 |
| 40 tabs, 1600 wide, sidebar off full screen | 528.3 / 618.9 / 618.9 | 523.1 / 544.9 / 544.9 |
| 40 tabs, 1600 wide, sidebar off windowed | 506.8 / 639.1 / 639.1 | 504.8 / 515.8 / 515.8 |
| 40 tabs, 1600 wide, sidebar on full screen | 541.1 / 666.5 / 666.5 | 522.9 / 632.3 / 632.3 |
| 40 tabs, 1600 wide, sidebar on windowed | 519.0 / 726.1 / 726.1 | 510.3 / 532.4 / 532.4 |
| 40 tabs, 2000 wide, sidebar off full screen | 517.7 / 593.8 / 593.8 | 517.7 / 535.8 / 535.8 |
| 40 tabs, 2000 wide, sidebar off windowed | 493.9 / 678.8 / 678.8 | 500.2 / 595.1 / 595.1 |
| 40 tabs, 2000 wide, sidebar on full screen | 518.0 / 626.6 / 626.6 | 504.4 / 541.6 / 541.6 |
| 40 tabs, 2000 wide, sidebar on windowed | 502.8 / 664.3 / 664.3 | 508.1 / 540.6 / 540.6 |

## Source validation

The final restored-branch source gate passed:

```text
Build complete! (29.65s)
OK 2281 checks passed
runner tests: 5 passed, 0 failed
```

A separate normal-debounce artificial-delay control with TRACE unset emitted two
CI warning annotations at 1837.663/1947.110 ms and still passed (1/1). It emitted
no timing JSON, confirming that the warning does not depend on TRACE. This
control is separate from the formal comparison samples.
The working tree was restored to fix/test-stability before the formal comparison;
all four modified code/test files matched the saved branch build inputs byte for
byte. No source changed during the paired run.
