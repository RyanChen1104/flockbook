<!-- Each user-visible change adds one line here, in the same branch. At release this file becomes vX.Y.Z.md. -->
## What's New in vX.Y.Z

One short line: what this release is about.

### ✨ New

- Overview cards show how long ago each agent last wrote its session log, at the right of its name (now, 24m, 3h, 2d). A tab with no agent log, such as a shell, shows no time.

### 🔒 Security

### 🐛 Bug Fixes
- An image you drop on the composer (a file, or a screenshot's thumbnail) or pick with Attach is now attached like a pasted one, and one Return sends it to Claude Code, Codex or Grok Build. Before, a drop on the composer did nothing at all: the glass card hid it from the drag. While you drag over the composer, its whole edge shows the drop outline.
- Prompt icons from powerlevel10k and other themes (git branch, folder) show in the terminal instead of boxes when a Nerd Font is installed: Flockbook uses Ghostty's font when it has the icons, else Menlo with the Nerd Font as its fallback.

### ⚙️ Changes

- Overview grouped by status shows every tab: a tab with no agent, such as a shell, is under Done and resting, so the card count matches the tab count in the header.
