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
- **TLS:** use it. With Tailscale Serve, Tailscale ends HTTPS with a real, auto-renewed certificate for `host.tailnet.ts.net`, and the PWA needs a secure context (HTTPS) for service workers and notifications anyway. On a LAN without Tailscale: a self-signed certificate. The QR code carries its fingerprint, but a browser cannot pin it (the browser owns TLS), so for the PWA it is for reference only; a native client pins it. On a LAN, someone on the same Wi-Fi who can fake the certificate (and gets the user past the browser warning) could take the pairing. So Tailscale is the recommended address: WireGuard authenticates every device.
- Tailscale already encrypts and authenticates devices. TLS + token still apply: a tailnet can hold other people's devices (shared nodes), and defense in depth is cheap here.
- **Mac hub, as built (phase 2):**
  - Bind: one address of this Mac, chosen in Settings > Remote access (default: the first Tailscale address, with the note that it is the safe choice; a LAN address is marked "less safe", with the warning above). Never all addresses (`0.0.0.0`, `::` are refused, not only off by default). Public addresses are refused. Every address except loopback needs TLS.
  - Certificate: self-signed P-256, made once with the system `/usr/bin/openssl` and kept in `Application Support/Flockbook/hub/tls` (mode 600 files in a mode 700 folder). It is imported in memory only, never into a keychain. A new certificate changes the fingerprint, so devices pair again.
  - The `tailscale cert` folder (a cert/key pair dropped into `<hub>/tailscale/`) is removed: Tailscale Serve (below) gives the same real certificate, renews it, and needs no files.
- **Tailscale Serve mode (recommended, the default mode):**
  - The hub listens on `127.0.0.1:7481` only, plain HTTP. `tailscale serve --bg --https=7480 http://127.0.0.1:7481` makes Tailscale end HTTPS at `https://<machine>.<tailnet>.ts.net:7480` for the tailnet only, with its own certificate. Port 7480 is our own, so the page is its own origin and another app's Serve config (often on 443, path `/`) is not touched. Direct mode moved to port 7482 so the two cannot clash on the Tailscale address.
  - Settings > Remote access shows a checklist, read again when the page shows and on Check Again (read-only: `tailscale status --json`, `tailscale serve status --json`): Tailscale on this Mac (the CLI inside `/Applications/Tailscale.app`, else on PATH), signed in, MagicDNS + HTTPS certificates (link to the admin DNS page), a phone on the tailnet (peers with their OS), Serve on for our port. Each step: one sentence, a tick, one action.
  - The app runs `tailscale serve` only when the owner clicks Turn On / Turn Off, and shows the exact command first, with Copy Command. Turn On only when port 7480 is free; Turn Off (`tailscale serve --https=7480 off`) only when port 7480 is exactly our handler. Anything else on that port, for any host name (another target, an extra path, a TCP forward, Funnel, a Tailscale Service, a serve running in a terminal), is shown as taken and left alone. The parser fails closed: a key or shape it does not know is "taken", never "off". The config is read again right before Turn On / Turn Off, and the command runs only for the state it read. Left: the moment between that read and the command (the CLI has no compare-and-set); another program would have to change port 7480 within it. Never Funnel, never `serve reset`.
  - Pairing behind Serve: every peer is 127.0.0.1, so wrong codes cannot be counted per address (one local process would lock out the phone). There, 3 wrong codes in all end the offer; the pairing sheet says "Code stopped after wrong tries" with a New Code button. Direct mode keeps 3 per address and 20 in all.
  - No trust from loopback: through Serve every request comes from 127.0.0.1, and Serve may rewrite Host. So the socket takes only the Origin `https://<machine>.<tailnet>.ts.net:7480` (exact match, Host ignored; no Origin = refused), and the device token is needed as always. A DNS-rebinding page (Host = Origin = its own name) is refused. Checks: `ChecksHubServe.swift`.
  - The QR link and the page address use the ts.net name. There is no certificate fingerprint in this mode.
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
| Stolen phone or leaked token | Per-device revoke (closes its open connections at once); tokens never shown again; `input` off by default per device |
| Token replay from a captured QR | Pairing secret is single use and short-lived |
| A malicious client sends raw keys | No raw-key API; only `send`, `approve`, `answer` with hub-side checks |
| Approve the wrong prompt (screen changed) | Hub re-reads the pane; prompt id must match the prompt on screen (a log id only when the log's call is that box); one more read right before the keys; an unreadable prompt counts as open (same rules as the notification) |
| A crafted image (decoder bug, decompression bomb, polyglot) | Only `input` devices; 10 MB and 16-part caps per image, 4 held per connection and 8 per device, 4 connections per device, a rate limit per device checked before decoding, 2 decodes at once; type from magic bytes, never from a name or MIME; pixel size checked from the header before decoding; always re-encoded into a new file, so nothing of the upload's bytes reaches the agent |
| Image metadata leaks (GPS, camera, time) | Re-encoding copies no metadata |
| The hub writes a file where it should not | Only into its own cache folder, a random name it makes, mode 600, created exclusively; no client path or name is used |
| Remote text into a shell, or control keys in text | `send` goes to agent panes only; text has no control characters except LF and tab, and a length cap |
| Remote text lands in a picker | `send` refuses while any prompt or picker is on screen or the agent is blocked, and reads the pane again right before the keys; every key of `send`, `approve` and `answer` is gated (same agent, same prompt on screen read last, `input` level now); an unreadable screen refuses every input. Residual: herdr has no compare-and-send, so a prompt that opens between the last read and the keys can still get them (milliseconds) |
| A question's own text (written by the agent) looks like picker rows, a focus mark or a Submit control, so a key picks another row | Remote answers only for questions from the agent's log (Codex); each key needs the screen to be the logged question's exact rendering, compared without whitespace, with the focus mark and the hub's notes checked by position. Questions read only from the screen (Claude Code: no log entry until answered) are answered on the Mac |
| A fake certificate on the LAN takes the pairing | Tailscale recommended (and default); LAN marked "less safe"; the fingerprint is for reference only in a browser |
| One peer burns the pairing offer | 3 wrong tries per source, 20 in all |
| Logs contain secrets (code, keys, tokens) | Read access is sensitive too: pairing is required even for `read`; nothing is cached on the phone beyond the open session (no offline store of conversations in v1) |
| The hub is a new process with your file access | Hub reads logs only; it writes only re-encoded images into its own cache folder (above); it runs as the user, not root |
| Hub left on by mistake | Off by default; a visible "Remote access on" state in the Mac app and in `flockbook-hub status`; optional auto-off after N days |

Defaults: hub off; when on, new devices are `read`; the app-wide "Allow input" setting still applies on top of the device level.

**Agent version bumps.** The exact-rendering check (`QuestionAdapter.codexExact`) holds Codex 0.162.1's picker as captured live: the head "Question k/n", the "None of the above" row and its description, the "› Add notes" field, the two key lines. When a new Codex version changes any of them, every remote answer to a Codex question refuses (nothing sent; the user answers on the Mac) until the template and its fixtures (`ChecksHubReview7`) are updated from a new live capture. On each Codex update: capture the picker in a test session (closed notes, empty notes, typed notes, a long wrapped description), run the checks, then a live answer from the hub. The same holds for Claude Code's template (`QuestionAdapter.claudeExact`, `claudeReviewExact`, fixtures in `ChecksClaudeHook`, captured from 2.1.296): on each Claude Code update, capture single, multiSelect, Other (empty, typed), Submit and the review screen, run the checks, then a live answer from the hub with a test settings file.

**Claude questions from the phone (option B, opt-in).** Claude Code writes AskUserQuestion to its log late (live: without a hook only after the answer; with a PreToolUse hook the call line may come while the picker is open, without a result), so the hub takes the question from a hook. Settings > Agents > "Answer Claude questions from the phone" (shown while Remote access is on) shows the exact entry and changes `~/.claude/settings.json` only on the owner's click: Install backs the file up next to it (`settings.json.flockbook-<time>.bak`), adds one `PreToolUse` entry (matcher `AskUserQuestion`, our script, timeout 5) and keeps every other key (the file is written back sorted and pretty-printed); twice = once; a file that is not plain JSON or a `hooks` of another shape is refused untouched. Uninstall removes only our entry. The script (in the app's Application Support) writes the hook's stdin JSON (at most 256 KB; the app reads only session_id, tool_use_id, tool_input) to a temp file and renames it into the app's records folder, mode 600; it prints nothing and always exits 0, so it never blocks or changes the call. The app reads the newest records, ignores and removes those over a day old. Binding: newest record of the agent's herdr session; no result for that call in the log; the screen is its exact rendering. A local process that writes a fake record gains nothing: a key goes only when the screen is that record's exact rendering, so the key does what the record's question says. Claude sessions started before Install do not have the hook; their questions stay "answer on the Mac".

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
- Built (phase 3, 2026-10-12): plain TypeScript and the DOM, no view library and no packages (`web/`;
  `scripts/web-build.mjs` writes `HubWebAssets.swift`). Pairing: the QR link (`#pair=…&fp=…`, read once, then removed
  from the address bar; the page shows the fingerprint for reference only) or the 6 words. The token is kept in
  the page's storage for its origin. List: Needs you first, then each workspace. Conversation: `#pane=<id>` (the back
  button works), Load earlier, tool chips, screen text. Cards: Allow / Deny and the picker question (a Claude set of
  questions uses the full set from the log, else "answer on the Mac"). Composer only for `input` devices, off while a
  prompt is open. In-app alert when another agent starts to need you; the count is in the page title. Reconnects
  (1–15 s) while paired. Not yet: service worker (offline shell), touch icon PNG, Web Push (phase 4).
- With a self-signed certificate the phone browser warns once; the page cannot check the pin itself (the browser
  owns TLS). The Tailscale Serve mode avoids the warning.
- Tests: `node scripts/web-test.mjs` (headless Chrome shell over DevTools, fake hub with TLS on 127.0.0.1, every
  screen and action) and `--live <session>` (the app's own hub, a read device, no input).

### 9.1 Image send (phone to agent)

The owner wants to send a photo or screenshot from the phone to an agent, as the Mac composer does with a pasted
image. The image is the dangerous part: a parser on the hub (image decoders are a classic attack surface), a file
the hub writes, and metadata (GPS) that the owner may not want in an agent's context.

Path, end to end:

1. PWA: an attach button in the composer (`<input type=file accept="image/*" multiple>`: camera or photo picker).
   Each pick shows a thumbnail with a remove button; at most 4. Files over 10 MB are refused on the phone with a
   message. Nothing is uploaded until Send.
2. Send: each image goes up as `attach` parts (protocol 3.3), with a progress bar; then one `send` names the
   finished uploads in `attachments` with the text (text may be empty).
3. Hub, per `attach`: level `input` (and the app-wide "Allow input"), size and count caps, a rate limit per device.
   The last part completes the upload: the type is read from the **magic bytes** (PNG, JPEG, HEIC, WebP); the
   file name and MIME type are never sent. The header's pixel size is checked before decoding (a decompression
   bomb is refused). ImageIO decodes the first frame only.
4. Hub, **re-encode always** (not only strip): the decoded pixels are drawn into a new image, with the EXIF
   orientation applied, the long side capped at 4096 px, and written as a new file: PNG when the source was PNG
   (screenshots stay sharp), else JPEG (quality 0.85). No metadata dictionary is copied, so EXIF, GPS, XMP, maker
   notes and comments are gone; whatever trailing bytes or polyglot content the upload carried is gone too.
5. File: the app's own cache folder, the same one the Mac composer uses (`~/Library/Caches/HerdrDesk/paste`, mode
   700), name `remote-<random UUID>.png|jpg`, created exclusively with mode 600. Never a client-chosen name or path.
6. `send` with `attachments`: all the `send` rules of protocol 3.1 still apply (agent pane only, no prompt open, a
   fresh read right before the keys). The message is the text and then the file paths, sent by the same code as
   the Mac composer (`MessageSender`): the text goes through herdr's normal text call without Enter
   (`pane.send_input`, so a newline stays inside the agent's input; seen live in Claude Code, Codex and pi), and
   each path goes as a **bracketed paste** (`ImagePaste`), because Claude Code turns a pasted image path into an
   attachment but keeps a typed one as text (seen live: typed -> plain path, pasted -> `[Image #1]`; Codex the
   same, pi keeps the path). Only a path that is one of our files right now is pasted: a name the app gives
   (`remote-<UUID>.png|jpg`, the composer's `<UUID>.png`) and an existing regular file, not a link; anything else
   stays text. For Claude Code and Codex the sender counts the `[Image #` markers in the input (below the last
   prompt line) before the paste, waits until the new ones show, and only then sends Enter. No new marker within
   5 s, or the screen cannot be read: no Enter, the send fails. The paste markers come only from the hub around
   its own file names; client text with ESC is refused (3.1), so a phone cannot open or close a paste.
   Right before the keys the hub reads the pane once more: the same agent (kind and session) the checks saw, not
   blocked, nothing on screen that takes keys; and before every key step it asks again whether the device still
   has `input` and Allow input is on. Left: the moment between that read and the keys (herdr has no
   compare-and-send).
7. Cleanup: unsent uploads are deleted when their connection closes, and when a fifth one replaces the oldest.
   Sent files stay for the agent to read. The hub's files in the folder are capped at 200 files and 512 MiB (the
   oldest go first) and 7 days, checked after every upload and every hour; the composer's launch purge also takes
   only the app's own names. Nothing else in the folder is ever deleted.
8. Folder: opened with `O_DIRECTORY|O_NOFOLLOW`, it must be a real directory owned by this user (else nothing is
   written), closed to mode 700, and the file is created inside the open folder (`openat`), so a folder swapped
   for a link meanwhile is not followed.

Agents: Claude Code turns the pasted path into an image attachment. Other agents get the path and read it with
their file tools (the same as from the Mac composer).



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
