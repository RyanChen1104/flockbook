# xplat

Cross-platform (Linux / Windows / macOS) spike for Flockbook in Rust + iced 0.14.
Phase A crates are spikes; each one answers one gate.

| Crate | Gate |
|---|---|
| `herdr-core` | Herdr link: socket client, JSON-RPC, snapshot, Claude/Codex parsers, fixture checks |
| `spike-select` | Drag-select and copy across rendered markdown blocks |
| `spike-virt` | Virtual list of 5,000+ messages, memory and frame-time bench |
| `spike-ime` | Text input with CJK preedit |

All spikes run headless (no window). Run `cargo test` in this directory.
