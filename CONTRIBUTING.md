# Contributing to Flockbook

Thank you for your interest. This page tells you how to build Flockbook, how to test a change, and how to send it.

## Before you start

- Flockbook is a native macOS reading view for [Herdr](https://herdr.dev) agents, written in Swift and SwiftUI.
- Flockbook is **unofficial**. It is not affiliated with Herdr, Inc. It uses only Herdr's public socket API. Do not add code that depends on Herdr internals.
- **Bugs:** open an issue with the bug report form.
- **Questions and help:** use [Discussions Q&A](https://github.com/minchenlee/flockbook/discussions/categories/q-a).
- **Feature ideas:** use [Discussions Ideas](https://github.com/minchenlee/flockbook/discussions/categories/ideas).
- **Security problems:** do not open a public issue. See [SECURITY.md](SECURITY.md).

## What to send

- **Small changes** (a typo, a small bug fix): send a pull request directly.
- **Large changes** (a new feature, a change to the architecture, a UI redesign): open an issue or a Discussion first. Agree on the approach before you write the code. This saves your time.
- Keep one pull request to one change.

## Build

You need:

- macOS with Swift 6.2 and the macOS 26 SDK: Xcode 26.1 or later, or the Command Line Tools 26.1 or later. We tested the steps below on macOS 26.1 with only the Command Line Tools 26.1 (Swift 6.2.1). CI uses Xcode 26.1.1.
- For the web checks (the phone page): Node 24, [Deno](https://deno.com) 2, and Playwright's `chrome-headless-shell` (`npx playwright install --only-shell chromium`, or set `CHROME_HEADLESS` to its path).

You do **not** need an Apple Developer ID, a signing identity, or any signing variable. Every command on this page works without them.

```sh
swift build                         # the app and the check tools
swift run HerdrKitChecks            # logic checks; prints "OK <n> checks passed"
node scripts/web-build.mjs --check  # the phone page assets match web/
node scripts/web-test.mjs           # the phone page in a headless browser
scripts/ui-checks.sh offline        # the app's UI checks, in offscreen windows
```

- `scripts/ui-checks.sh offline` needs an unlocked screen. It stops when the screen is locked.
- `scripts/bundle.sh` makes `build/Flockbook.app` with an ad-hoc signature. You only need it to try the app as a bundle.
- If you change a file in `web/`, run `node scripts/web-build.mjs` (without `--check`), then `swift build`, then the web checks.

## Test your change

- **Bug fix:** first write a check that fails (red) and commit it. Then fix the bug (green) in a second commit. Most logic checks are in `Sources/HerdrKitChecks/`.
- **UI change:** attach screenshots in light mode and in dark mode to the pull request.
- Run all the checks above before you send the pull request. Say in the pull request which checks you ran.
- To run only some UI checks, name them: `ONLY="question busy-tab" scripts/ui-checks.sh offline`.
- **User-visible change:** add one line to `docs/release-notes/next.md`, under its section, in the same pull request.

Two rules protect your own agents:

- **Do not send input to your working Herdr session.** A check that types, resizes or takes over a pane must use a separate session. Make a demo session with `scripts/demo-seed.sh` and pass `--session flockbook-demo` to the app. The demo session has only fictional projects.
- **Do not open visible windows in checks.** The offline UI checks draw offscreen. `scripts/ui-checks.sh real` opens a real window and takes the focus; it is for CI.

Test fixtures under `Tests/` and `Sources/HerdrKitChecks/` must be synthetic. Do not commit real session logs.

## Commit messages

Look at `git log` for examples. The style:

- `Area: what changed, in plain words`, for example `Terminals: find herdr where its installer puts it`.
- A red commit ends with `(red)`, for example `Checks: a terminal that cannot start says why (red)`.
- Use the body to say why, in short sentences.

## Releases

1. Rename `docs/release-notes/next.md` to `docs/release-notes/vX.Y.Z.md`. Fill in the version and one short intro line. Delete empty sections.
2. Add a new `next.md` from the old template (the comment line and the four empty sections).
3. Commit both, then push the tag `vX.Y.Z`. The release page is that file, plus Installation and the Full Changelog link (`scripts/release-notes.sh`).

## AI-assisted contributions

You are welcome to use AI tools. We use them to build Flockbook too (see [How this was built](README.md#how-this-was-built)). Good review matters more than who or what typed the code. We ask three things:

- Read and understand every line you send. You are the author, and you answer for the change.
- In the pull request, say in one line which tools you used, for example "Claude Code wrote the first draft; I reviewed and edited it."
- Run the checks yourself.

## License

Flockbook is under the MIT License. When you send a contribution, you agree that it is licensed under the MIT License too (see [LICENSE](LICENSE)).
