# macOS 26.6 UI check investigation

Baseline: `68aa63b` (2026-10-25).

The four failures in [run 40059228397](https://github.com/minchenlee/flockbook/actions/runs/40059228397)
are already addressed in this baseline:

- `island-height`: the Reduce Transparency capsule measured 38 pt against the
  36 pt toolbar buttons. `d1834a9` moved the hairline inside the capsule with
  `strokeBorder`; `e72f060` kept that overlay from taking tab clicks.
- `settings-page` and `screencolumn`: a synthetic wheel did not move an offscreen
  SwiftUI scroll view. `bd50402` checks the responder route and programmatic
  scrolling in that case. These are offscreen routing/layout checks; they do
  not establish real-window wheel behavior.
- `glyph`: the runner enables Reduce Motion. `bd50402` expects a still glyph
  with that setting and animation otherwise; it retains the idle control and
  CPU comparison.

[Run 40198186245](https://github.com/minchenlee/flockbook/actions/runs/40198186245)
executed all four checks successfully on both macOS 26 and macOS 15 at this exact
baseline. No additional app change or assertion relaxation is needed for these
historical failures. Local macOS 26.1 offscreen validation also passed all four.
