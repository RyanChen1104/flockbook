# Composer check investigation

Baseline: `68aa63b`, macOS 26.1, offscreen windows only (2026-10-25).

The verified composer failure in [run 40173502245](https://github.com/minchenlee/flockbook/actions/runs/40173502245)
was in the macOS 15 release app at `21fa6b7`. File and screenshot-promise drops
found no target; the outline and chip checks then failed (`FAIL x10`). That
revision deliberately disabled FakeDrag's private AppKit hit test in release
builds and returned no target. This is a deterministic check implementation
failure in that build configuration, rather than evidence of an app timing race.

`9e586ad`, already in the baseline, fixes the root cause with a public-API walk
of registered drag destinations. Debug builds compare its result with AppKit's
own hit test. [Run 40198186245](https://github.com/minchenlee/flockbook/actions/runs/40198186245)
passed composer on both macOS 26 and macOS 15 at this baseline.

Local repetition uses the script's actual selection interface:

```sh
for i in $(seq 1 20); do
    ONLY=composer scripts/ui-checks.sh offline "build/composer-repeat/$i"
done
```

Each invocation starts a fresh app process. The check covers IME placeholders,
drafts, image/text paste, image removal and sending, drag routing and its
outline, screenshot promises, and synthetic host uploads. No live pane is used.

The historical CI issue is already fixed in main. These checks cannot establish
that every separate intermittent failure is resolved; a new failure needs its
specific failing step and build configuration before another app change is
justified. No additional app change or assertion relaxation is made here.

## Local results

Two consecutive batches, each with 20 fresh processes on the unchanged baseline:

- Initial batch: 20/20 passed, failure rate 0/20 (0%).
- Confirmation batch: 20/20 passed, failure rate 0/20 (0%).
- `swift build`: succeeded.
- `swift run HerdrKitChecks`: `OK 2277 checks passed`.

These are validation of the fix already in main, not before/after evidence of a
new change in this branch. No additional intermittent failure was reproduced.
