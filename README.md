# Flockbook for Herdr

> **Unofficial.** Flockbook is not affiliated with, endorsed by, or supported by Herdr, Inc. It uses only Herdr's public socket API.

Flockbook is a native macOS reading view for your [Herdr](https://herdr.dev) agents. Read what each agent did, see which one needs you, and reply in one place.

Your agents' conversations are already in the terminal. Flockbook shows the same conversation in a layout that is easier to read.

## Requirements

- macOS 26 or later
- Herdr, running
- Agents in Herdr: Claude Code, Codex, Cursor, or pi. Flockbook reads their local session logs to show the conversation.

## Releases

Download the latest `Flockbook-<version>.dmg` or `.zip` from GitHub Releases. Builds are universal (Apple silicon and Intel). Check the download against `SHA256SUMS`.

Release notes say whether a build is signed and notarized. An unsigned build is blocked by macOS on first open; to run it anyway:

```sh
xattr -dr com.apple.quarantine /Applications/Flockbook.app
```

## Build

```sh
scripts/bundle.sh    # builds build/Flockbook.app (ad-hoc signed)
scripts/package.sh   # dist/Flockbook-<version>.zip and .dmg
```

## Privacy

Flockbook runs locally. It reads agent session logs on your Mac (`~/.claude/projects/`, `~/.codex/sessions/`, `~/.cursor/projects/`, `~/.pi/agent/sessions/`) and talks to Herdr through its local socket. It sends nothing over the network and has no telemetry.

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
