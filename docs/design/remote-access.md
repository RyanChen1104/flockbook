# Remote access: phone and remote hosts

Status: design, not built. Date: 2026-10-11.
Decision so far: the Mac is the hub, the network is Tailscale, the phone client is a web PWA. Remote access is opt-in and off by default.
Order (owner, 2026-10-11): phone for the Mac first (Swift hub in the app + PWA). The Linux remote comes later, as one block: option 0 (`ssh -L`), the Rust hub and the Mac app remote mode together.

## 1. Goals

1. **Phone:** see your agents, read their conversations, and answer approvals from a phone.
2. **Remote host:** the Mac app shows a herdr that runs on another machine (usually Linux).
3. Both use **one protocol**, served by **one hub** on the machine that runs herdr.

Non-goals: a public internet service, accounts, a relay server, multi-user sharing.

## 2. What the app reads today

| Data | Source | Works over a forwarded socket? |
|---|---|---|
| Workspaces, tabs, panes, agent status | herdr socket (`LineSocket`, NDJSON): `session.snapshot`, `events.subscribe` | Yes |
| Pane screen (prompt check, question picker) | herdr socket: `pane.read` | Yes |
| Input, keys, approve, answer | herdr socket: `pane.send_text`, `pane.send_keys` | Yes |
| Live terminal | `herdr terminal session observe` or `control` child process | Only with a local `herdr` binary of the same version |
| Conversation text | Log files on disk: `~/.claude/projects/*.jsonl`, Codex rollouts, pi, cursor (`SessionLog`) | **No**: the files are on the remote disk |
| Log lookup when herdr gives no session | `ps` + `lsof` on the herdr machine (`SessionResolver`) | **No** |
| Git branch, file picker, pasted images | Local `git`, local paths | **No**: paths are on the other machine |

Conclusion: the socket carries status, screens and input. The conversation, the core of the app, needs code that runs next to the log files.

## 3. Option 0: SSH socket forward (deferred to the Linux remote block)

```
ssh -N -L ~/.flockbook/remote/devbox.sock:/home/me/.config/herdr/herdr.sock me@devbox
```

The Mac app then connects with a new launch option, for example `--socket ~/.flockbook/remote/devbox.sock`.

What works: sidebar, status, the "Needs you" list, notifications, the approval card and question card **from the screen** (the screen fallback in `ApprovalNotice` was made for a log-less Claude; it also covers this case), composer input.

What fails: conversation text (empty, "log not found"), log-based question cards (Codex), the terminal sheet unless `herdr` is installed on the Mac, git branch, file attach and image paste (wrong machine).

Size: S (one launch option, one "Remote (limited)" banner, hide what cannot work). It is done together with the Linux remote (phase 5), not first: alone it gives a Mac view without conversations, and the phone does not need it.

## 4. Target design: one hub, one protocol

```
  Phone (PWA)          Mac app (remote mode)        Mac app (local, today)
       │ HTTPS/WSS            │ WSS                         │
       └──────────┬───────────┘                             │
            Tailscale / LAN                                 │
                  │                                         │
  ┌───────────────▼─────────────────────┐                   │
  │ Hub (on the machine that runs herdr)│◄──────────────────┘ (optional:
  │  herdr client · log readers ·       │     the local app may also
  │  parsers · approval rules · auth    │     use the hub, later)
  └───────────────┬─────────────────────┘
                  │ Unix socket (NDJSON)      log files (read-only)
             herdr server                     ~/.claude/projects, …
```

The hub runs on the herdr machine. It reads herdr and the log files there, parses them there, and sends **parsed** data to clients. Clients never read files and never talk to herdr directly.

### 4.1 Protocol

One WebSocket per client, JSON messages. Plain HTTPS for the PWA files and for pairing.

Server to client (push):
- `snapshot`: workspaces, tabs, panes, agents (same model as `Workspace`/`Tab`/`Pane`).
- `status`: one agent's status changed.
- `conversation`: items for one session (`ConversationItem` as JSON), with a cursor. First a tail, then appends. `loadEarlier` pages back.
- `screen`: the visible text of one pane, on request or while a client watches it.
- `prompt`: an approval or question is open (from `ApprovalNotice` / `QuestionAdapter`), with its id.

Client to server (requests, each with an id and a reply):
- `watch` / `unwatch` a pane (limits what the hub reads and sends).
- `send` text to a pane (composer).
- `approve` {pane, prompt id, allow}: the hub re-reads the pane and sends only when the id is still current (same rule as the notification buttons).
- `answer` {pane, question id, answers}.
- `loadEarlier` {session, cursor}.

Rules:
- The hub owns all decisions about keys. Clients send intent (`approve`, `answer`), never raw keys. This keeps the verified key sequences in one place.
- Every message has a protocol version. The hub refuses an unknown major version.
- No terminal byte stream in v1. The PWA shows the parsed conversation and the screen text. A full remote terminal is a later phase.

### 4.2 Which code runs the hub

| | Swift (HerdrKit) | Rust (`xplat/herdr-core`) |
|---|---|---|
| Runs on Linux | Swift on Linux is possible, but HerdrKit uses Foundation/Darwin APIs (`ps -E`, `lsof` flags, file watchers) | Yes, built and tested on Linux CI today |
| Parsers | Original, most tested | Port of the same parsers, with fixture checks |
| Single binary for a server | Harder (Swift runtime) | Easy (`cargo build --release`, static-ish) |
| Mac hub | Natural: the app process already has the data | Possible as a sidecar binary |

Recommendation:
- **Mac hub = Swift, inside the app**, built first (phase 2), because the app already holds the store, the logs and the approval rules. It uses `Network.framework` (`NWListener` with TLS and WebSocket); no new dependency.
- **Linux hub = Rust**, a new crate `xplat/flockbook-hub` on top of `herdr-core`, built later (phase 5). It runs headless (`flockbook-hub --session <name>`), as a user service. Same protocol, same message types.
- Keep the two in step with **shared protocol fixtures**: JSON files of every message type, checked by HerdrKitChecks and by `cargo test`.

Risk: two implementations of the same rules. Mitigation: the fixtures, and the hub rules stay thin (they call the parsers both sides already have).

## 5. Transport

- **Tailscale or LAN only.** The hub listens on the Tailscale interface address (100.x / fd7a:…) or on a LAN address the user picks. Never on `0.0.0.0` by default.
- **TLS:** use it. With Tailscale, `tailscale cert` gives a real certificate for `host.tailnet.ts.net`, and the PWA needs a secure context (HTTPS) for service workers and notifications anyway. On a LAN without Tailscale: a self-signed certificate, pinned at pairing (the QR code carries its fingerprint).
- Tailscale already encrypts and authenticates devices. TLS + token still apply: a tailnet can hold other people's devices (shared nodes), and defense in depth is cheap here.
- **Mac hub, as built (phase 2):**
  - Bind: one address of this Mac, chosen in Settings > Remote access (default: the first Tailscale address). Never all addresses (`0.0.0.0`, `::` are refused, not only off by default). Public addresses are refused. Every address except loopback needs TLS.
  - Certificate: self-signed P-256, made once with the system `/usr/bin/openssl` and kept in `Application Support/Flockbook/hub/tls` (mode 600 files in a mode 700 folder). It is imported in memory only, never into a keychain. A new certificate changes the fingerprint, so devices pair again.
  - Tailscale certificate: when the owner runs `tailscale cert --cert-file <hub>/tailscale/cert.pem --key-file <hub>/tailscale/key.pem <name>.ts.net` and the hub uses a Tailscale address, the hub uses that pair. The app never runs `tailscale cert` itself (it requests a public certificate, and the name goes into public certificate logs). An EC certificate with explicit curve parameters is refused, because the in-memory import crashes on it.
  - State in sight: the Settings row says "Off. Nothing listens." or "On at https://…" (the PWA; its socket is `/ws`), and while on, the sidebar foot shows "Remote access on".

## 6. Pairing and auth

1. On the hub machine: Settings > Remote access > "Pair a device" (Mac), or `flockbook-hub pair` (Linux). It shows a QR code and a 6-word code.
2. The QR holds: hub URL, certificate fingerprint, a one-time pairing secret (valid 5 minutes, single use).
3. The client opens the URL, sends the secret, and gets a **device token** (random 256-bit). The hub stores only a hash of it, with a device name and the date. (Mac hub: a JSON file, mode 600, in Application Support. A hash is not a secret; the Keychain would ask again after every rebuild of an ad-hoc signed app.)
4. Every WebSocket opens with the device token. The hub lists paired devices and can revoke one.
5. Each device has a **permission level**: `read` (default) or `input`. `input` must be turned on per device, on the hub, not on the client.

## 7. Threat model

Input to an agent pane is remote code execution: an agent with tool access runs what it is told, and "Allow" approves a command.

| Threat | Control |
|---|---|
| Someone on the network reaches the hub | Tailscale/LAN bind only; TLS; device token required |
| Stolen phone or leaked token | Per-device revoke; tokens never shown again; `input` off by default per device |
| Token replay from a captured QR | Pairing secret is single use and short-lived |
| A malicious client sends raw keys | No raw-key API; only `send`, `approve`, `answer` with hub-side checks |
| Approve the wrong prompt (screen changed) | Hub re-reads the pane; prompt id must match (same rule as the notification) |
| Logs contain secrets (code, keys, tokens) | Read access is sensitive too: pairing is required even for `read`; nothing is cached on the phone beyond the open session (no offline store of conversations in v1) |
| The hub is a new process with your file access | Hub is read-only on the file system (logs only); it never writes files; it runs as the user, not root |
| Hub left on by mistake | Off by default; a visible "Remote access on" state in the Mac app and in `flockbook-hub status`; optional auto-off after N days |

Defaults: hub off; when on, new devices are `read`; the app-wide "Allow input" setting still applies on top of the device level.

## 8. Mac app: adding a remote host (phase 5)

- Sidebar footer: a host switcher ("This Mac", "devbox"). One window shows one host; a second window can show another.
- Settings > Hosts > "Add host": paste the hub URL and type the 6-word code that the hub shows (a Mac has no QR scan step). The app stores the device token in the Keychain.
- Status per host: connected / reconnecting / offline, and the device level (`read` / `input`). When the level is `read`, the composer shows "Read-only on devbox" (same pattern as the read-only launch).
- Things that need the local machine are hidden for a remote host: file attach, image paste, git branch, terminal sheet (until phase 6).
- Notifications: the Allow / Deny buttons are shown only when the device level is `input`.

## 9. Phone PWA

- Served by the hub over HTTPS. Installed with "Add to Home Screen".
- Screens: agent list (Needs you first), conversation (read), approval card, question card, composer (only with `input`).
- Notifications: Web Push needs a push service; v1 uses in-app alerts while the PWA is open. Web Push (iOS 16.4+ for installed PWAs) is a later phase.
- Small: plain TypeScript + one view library, no build server in production; files are embedded in the hub binary.

## 10. Phased plan

Phone for the Mac first. The Linux remote follows as one block.

| Phase | Content | Size |
|---|---|---|
| 1 | Protocol spec + JSON fixtures for every message type. Checked by HerdrKitChecks now and by `cargo test` later. | S (3–5 days) |
| 2 | Swift hub in the Mac app: Settings > Remote access (off by default), `NWListener` on the Tailscale address, TLS (`tailscale cert`), pairing (QR + 6-word code), device tokens (hash only, in a mode-600 file), per-device `read`/`input`, revoke. Serves snapshot, events, conversation, screen, `send`/`approve`/`answer`. Headless tests with a test client against a named session. | L (2–3 weeks) |
| 3 | PWA served by the hub: agent list, conversation, approval and question cards, composer (only with `input`). Phone check by the owner. | M (1–2 weeks) |
| 4 | Web Push for "Needs you" (installed PWA, iOS 16.4+), with Allow / Deny only for `input` devices. | S–M (1 week) |
| 5 | Linux remote, one block: option 0 (`--socket` + `ssh -L`, the limited mode), the Rust `flockbook-hub` on Linux (same protocol and fixtures), and the Mac app remote mode (host list, Keychain token, a `RemoteStore` that feeds the same views as `HerdrStore`). | L (3–4 weeks) |
| 6 | Remote terminal stream (both hubs). | L (3+ weeks) |

## 11. Open questions

1. Does herdr plan its own remote or TCP listener? If yes, option 0 and the hub's herdr link (phase 5) may change.
2. The minimum Linux distro and the service manager (systemd user unit only?).
3. Should a device's `input` level expire (for example after 24 hours) and need a re-confirm on the hub?
4. Is one hub per herdr session enough, or should one hub serve all sessions on a machine?
