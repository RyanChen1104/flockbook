<!-- Each user-visible change adds one line here, in the same branch. At release this file becomes vX.Y.Z.md. -->
## What's New in vX.Y.Z

One short line: what this release is about.

### ✨ New
- Remote herdr: Flockbook can show the agents of a herdr that runs on another machine over ssh. Conversations, the reply field, pictures and attached files, the terminal, the git branch, the Claude Code question hook and the status line work on the host. Attached files and pictures are copied to the host first. The host needs herdr's integration for the agent (`herdr integration install claude`, `codex` or `grok`); without it the conversation says so.
- Settings > General > Machine: choose which machine the window shows (this Mac, or a host over ssh). The switch takes effect after a relaunch.

- Overview cards show how long ago each agent last wrote its session log, at the right of its name (now, 24m, 3h, 2d). A tab with no agent log, such as a shell, shows no time.

### 🔒 Security

### 🐛 Bug Fixes
- A picture sent with a long message is submitted again: when the agent's input wrapped inside `[Image #n]`, Flockbook did not see the picture and left the message unsent in the input.
- An image you drop on the composer (a file, or a screenshot's thumbnail) or pick with Attach is now attached like a pasted one, and one Return sends it to Claude Code, Codex or Grok Build. Before, a drop on the composer did nothing at all: the glass card hid it from the drag. While you drag over the composer, its whole edge shows the drop outline.
- Prompt icons from powerlevel10k and other themes (git branch, folder) show in the terminal instead of boxes when a Nerd Font is installed: Flockbook uses Ghostty's font when it has the icons, else Menlo with the Nerd Font as its fallback.

### ⚙️ Changes

- Overview grouped by status shows every tab: a tab with no agent, such as a shell, is under Done and resting, so the card count matches the tab count in the header.
