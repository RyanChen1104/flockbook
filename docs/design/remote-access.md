# Remote access: phone and remote hosts

Status: design, not built. Date: 2026-10-11.
Decision so far: the Mac is the hub, the network is Tailscale, the phone client is a web PWA. Remote access is opt-in and off by default.

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

## 3. Option 0: SSH socket forward (first step, no new code)

```
ssh -N -L ~/.flockbook/remote/devbox.sock:/home/me/.config/herdr/herdr.sock me@devbox
```

The Mac app then connects with a new launch option, for example `--socket ~/.flockbook/remote/devbox.sock`.

What works: sidebar, status, the "Needs you" list, notifications, the approval card and question card **from the screen** (the screen fallback in `ApprovalNotice` was made for a log-less Claude; it also covers this case), composer input.

What fails: conversation text (empty, "log not found"), log-based question cards (Codex), the terminal sheet unless `herdr` is installed on the Mac, git branch, file attach and image paste (wrong machine).

Size: S (one launch option, one "Remote (limited)" banner, hide what cannot work). Value: try remote use this week, and learn which parts people use.

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
- **Linux hub = Rust**, a new crate `xplat/flockbook-hub` on top of `herdr-core`. It runs headless (`flockbook-hub --session <name>`), as a user service.
- **Mac hub = Swift, inside the app** (phase 2), because the app already holds the store, the logs and the approval rules. Same protocol, same message types.
- Keep the two in step with **shared protocol fixtures**: JSON files of every message type, checked by HerdrKitChecks and by `cargo test`.

Risk: two implementations of the same rules. Mitigation: the fixtures, and the hub rules stay thin (they call the parsers both sides already have).

## 5. Transport

- **Tailscale or LAN only.** The hub listens on the Tailscale interface address (100.x / fd7a:…) or on a LAN address the user picks. Never on `0.0.0.0` by default.
- **TLS:** use it. With Tailscale, `tailscale cert` gives a real certificate for `host.tailnet.ts.net`, and the PWA needs a secure context (HTTPS) for service workers and notifications anyway. On a LAN without Tailscale: a self-signed certificate, pinned at pairing (the QR code carries its fingerprint).
- Tailscale already encrypts and authenticates devices. TLS + token still apply: a tailnet can hold other people's devices (shared nodes), and defense in depth is cheap here.

## 6. Pairing and auth

1. On the hub machine: Settings > Remote access > "Pair a device" (Mac), or `flockbook-hub pair` (Linux). It shows a QR code and a 6-word code.
2. The QR holds: hub URL, certificate fingerprint, a one-time pairing secret (valid 5 minutes, single use).
3. The client opens the URL, sends the secret, and gets a **device token** (random 256-bit). The hub stores only a hash of it, with a device name and the date.
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

## 8. Mac app: adding a remote host

- Sidebar footer: a host switcher ("This Mac", "devbox"). One window shows one host; a second window can show another.
- Settings > Hosts > "Add host": paste the hub URL and type the 6-word code that the hub shows (a Mac has no QR scan step). The app stores the device token in the Keychain.
- Status per host: connected / reconnecting / offline, and the device level (`read` / `input`). When the level is `read`, the composer shows "Read-only on devbox" (same pattern as the read-only launch).
- Things that need the local machine are hidden for a remote host: file attach, image paste, git branch, terminal sheet (until phase 4).
- Notifications: the Allow / Deny buttons are shown only when the device level is `input`.

## 9. Phone PWA

- Served by the hub over HTTPS. Installed with "Add to Home Screen".
- Screens: agent list (Needs you first), conversation (read), approval card, question card, composer (only with `input`).
- Notifications: Web Push needs a push service; v1 uses in-app alerts while the PWA is open. Web Push (iOS 16.4+ for installed PWAs) is a later phase.
- Small: plain TypeScript + one view library, no build server in production; files are embedded in the hub binary.

## 10. Phased plan

| Phase | Content | Size |
|---|---|---|
| 0 | `--socket` launch option, "Remote (limited)" banner, hide what cannot work over a forwarded socket. Doc for the `ssh -L` setup. | S (2–3 days) |
| 1 | Protocol spec + JSON fixtures. Rust `flockbook-hub` on Linux: snapshot, events, conversation (tail + append + loadEarlier), screen, `send`/`approve`/`answer`, pairing, tokens, TLS. Headless tests against a fake herdr and fixture logs. | L (2–3 weeks) |
| 2 | Mac app remote mode: host list, Keychain token, a `RemoteStore` that feeds the same views as `HerdrStore`. | M (1–2 weeks) |
| 3 | PWA: list, conversation, approval and question cards, composer. Hub serves it. Phone check by the owner. | M (1–2 weeks) |
| 4 | Mac app as hub (Swift, same protocol) so the phone can reach a Mac-only setup; Web Push; remote terminal stream. | L (3+ weeks) |

Order note: if the first need is "phone for my Mac", swap phases 2 and 4 partly: build the Swift hub in the app first, then the PWA. The protocol and fixtures from phase 1 come first either way.

## 11. Open questions

1. Does herdr plan its own remote or TCP listener? If yes, phase 0 and the hub's herdr link may change.
2. The minimum Linux distro and the service manager (systemd user unit only?).
3. Should a device's `input` level expire (for example after 24 hours) and need a re-confirm on the hub?
4. Is one hub per herdr session enough, or should one hub serve all sessions on a machine?
