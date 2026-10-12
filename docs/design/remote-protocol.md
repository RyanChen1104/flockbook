# Remote protocol v1

Status: spec, phase 1 of `remote-access.md`. Date: 2026-10-12.
Swift types: `Sources/HerdrKit/HubProtocol.swift`. Fixtures: `Tests/HerdrKitTests/Fixtures/hub/` (one file per message type; the Rust hub must pass the same files).

## 1. Transport and framing

- One WebSocket per client. One JSON object per text frame. UTF-8.
- One origin: the hub serves the PWA files over HTTPS (`GET /`, `/app.js`, …; a fixed table, no file system) and takes the
  socket on `GET /ws` (RFC 6455 upgrade). Other paths: 404. Other methods: 405. Request head over 16 KB: 431.
- An upgrade with an `Origin` header is taken only when the origin's host and port equal the `Host` header (the hub's own page); else 403.
  Clients without `Origin` (native apps) are let in; the token still decides.
- Client frames must be masked and have no RSV bits (no extensions); else close 1002. A message over the size limit
  (1 MB) closes with 1009, read from the length field before any payload.
- Limits: a connection without a paired device (a file request, pairing, before `hello`) is closed after 10 s; at most
  16 such connections and 64 in all are held at once; more are refused at accept.
- Off by default; listens on one address only (`remote-access.md` section 5).

## 2. Envelope

Every message has:

| Field | Type | Rule |
|---|---|---|
| `v` | int | Protocol major version. This spec is `1`. A receiver refuses another major version (`unsupportedVersion`) and closes. |
| `type` | string | Message type (below). The hub replies `badRequest` to an unknown client type. A client skips an unknown hub type (so the hub can add push types). |

Client messages also have `id` (string, unique per connection). The hub answers every client message with exactly one `reply` (`re` = that `id`). Data comes as push messages; `reply` only says done or not done.

Hub push messages have no `id`.

Field names are camelCase. Optional fields are left out when empty (never `null`).

## 3. Client to hub

The client sends **intent only**. There is no message that carries raw keys or terminal bytes (`attach` carries image data, which the hub re-encodes into a file; it never reaches the terminal). The hub turns intent into keys with the same code the Mac app uses (`HerdrClient.respond`, `answerQuestion`, the composer send).

| `type` | Fields | Effect |
|---|---|---|
| `pair` | `secret`, `name` | New device only, before `hello`. `secret`: the pairing secret from the QR code, or the 6 words the hub shows (any case, any separators). A good one gets `paired` with a new device token. A wrong or expired one gets `unauthorized` and a close. After `hello` it gets `badRequest`. See 3.2. |
| `hello` | `token`, `client` (name), `clientVersion` | First message of a paired device. The hub checks the device token, then sends `welcome` + `snapshot`. Anything else before `hello` (except `pair`) gets `unauthorized`. |
| `watch` | `pane` | Start pushes for this pane: `conversation` (tail), `screen`, `prompt`. |
| `unwatch` | `pane` | Stop them. |
| `loadEarlier` | `session`, `before` (item id) | Push older items as `conversation` with `mode: "prepend"`. |
| `send` | `pane`, `text`, `attachments?` | Type `text` into the agent and submit it, as the composer does. `attachments`: up to 4 finished `attach` uploads of this connection; their file paths follow the text. `text` may be empty when there are attachments. Needs level `input`. |
| `attach` | `upload`, `part`, `parts`, `data` | One part of an image for a later `send`. See 3.3. Needs level `input`. |
| `approve` | `pane`, `prompt`, `allow` | Answer the open permission prompt. `prompt` is the id from the last `prompt` push. Needs level `input`. |
| `answer` | `pane`, `question`, `answers` | Answer the open question. `answers`: one per question, `{picks: [int], other?: string}` (0-based option indexes). Needs level `input`. |
| `ping` | – | The hub sends `pong`. |

### 3.1 Input rules: approve, answer, send

The hub checks every input against the pane as it is **now**, read again when the message arrives. A rule that fails sends nothing.

**approve.** 
The hub re-reads the pane when `approve` arrives (`ApprovalNotice.outcome`). It sends the approval card's input only when the prompt with that id is still open and input is allowed. Otherwise it sends nothing and replies `stale` (or `readOnly`). The id is the one `ApprovalNotice.prompt` gives: the log's pending tool call id, or `screen-<hash>` of the prompt box when the log has none. The notification buttons, the in-app card and remote clients all use this same id.

The log can lag the screen. So when a prompt box is on screen, the id must be the screen id, or the log id only when the log's pending call is that box (same tool, same command, spaces aside). A client that holds an older log id gets `stale` while the screen shows another prompt. The hub reads the pane once more right before the keys go out and sends nothing if the prompt changed in between (`stale`). The Mac notification path uses the same two checks.

The in-app card binds its buttons to the request it shows (`ApprovalNotice.cardRequest`: the log's call when it is the box on screen, else the box) and sends through the same re-check.

A screen that shows a permission prompt the hub cannot read (the marker line, but no prompt box it can parse) counts as an open prompt: `approve` replies `stale` (no id matches), `send` replies `promptOpen`. The hub fails closed.

**answer.** The hub reads the open question again (Claude: the picker on screen; Codex: the pending question in the log). It answers only when that question's id equals `question`. Otherwise it replies `stale`. Only a picker question can be answered from a client (`delivery: "picker"`, as in the app); a `message` question replies `failed`. Claude shows one question of a set at a time (`headers` names all of them). The hub then reads the others first (navigation keys only, as the app card does) and needs one answer per question; a different count replies `failed` and nothing is chosen.

**send.** Only to an agent pane: a plain shell replies `readOnly` (shell input stays off remotely). When the pane has an open prompt (an approval, a question, a prompt the hub cannot read, a blocked agent, or any picker with its key line on screen, such as Claude's setup or folder-trust pickers), the hub refuses with `promptOpen` and sends nothing. Text typed into a permission prompt or a picker would choose an option. The client shows the prompt instead; the user answers it, then sends. Right before the keys, the hub reads the pane again (a fresh snapshot and screen: the agent is still there, not blocked, no picker); if that changed, it replies `promptOpen` and sends nothing.

Multi-line text is one message: the hub types it as the Mac composer does (`pane.send_input`, the text, then Enter). Checked live in a test session on 2026-10-12: Claude Code 2.1.296, Codex 0.162.1 and pi each took a two-line message as one submission (one answer to both lines).

**Unreadable screen.** When the hub cannot read the pane's screen, `send`, `approve` and `answer` reply `failed` and send nothing. Without the screen the hub cannot tell what the keys would answer.

**Every key is gated.** For `send`, `approve` and `answer` the hub asks a gate (`KeyGate`) right before every key
it sends, not only once: the pane still shows the agent the checks saw (same kind and session, fresh snapshot); the
screen still shows what the key is for (the same approval box, this question's picker, the new image markers before
Enter), read last; and the device still has `input` and Allow input is on. Any no stops the input there; the keys
after it are not sent (`failed`, or `readOnly` when the level changed). A multi-key answer can stop half way; the
picker then shows where it stopped.

**What stays open.** herdr has no compare-and-send: the last read and the keys are two calls. A prompt that opens in the milliseconds between them can still get the keys. The checks make this window small; they cannot close it. (The Mac card and notification buttons have the same window.)

**Text rules (send, and each `other` of answer).** At most 16,000 characters for `send` and 2,000 for `other`. No control characters except line feed and tab: no ESC (so no bracketed-paste markers or key sequences), no CR, no other C0, no DEL, no C1 (U+0080–U+009F). A breach replies `badRequest` and sends nothing.

Order of checks for all three: device level and the app-wide "Allow input" (`readOnly`), the pane exists (`notFound`), then the rule above.

### 3.2 Pairing

The hub owner starts pairing on the hub. The hub then holds **one offer**: a secret (256-bit, base64url) for the QR code and 6 words (from a fixed list of 256, so 48 bits) to type. The offer:

- lasts 5 minutes;
- is single use: a good `pair` ends it;
- every wrong `pair` closes its connection;
- refuses a source (the peer address) after 3 wrong `pair` messages from it, even with the right secret after that, so one peer cannot use up the owner's offer;
- ends after 20 wrong `pair` messages in all;
- is replaced by a new offer.

A good `pair` adds a device with level `read`. Input is turned on per device on the hub. The hub stores only the SHA-256 of the token, the device id, name, level and pair date. The token is shown once, in `paired`; the client keeps it and sends `hello` with it, on this connection or a new one.

The QR code holds a link: `<hub URL>/#pair=<secret>&fp=<certificate SHA-256>`. Both values are in the fragment, which a browser never sends to a server. A browser cannot pin `fp` (the browser owns TLS; the page cannot see the certificate), so the PWA shows it for reference only. A native client pins it.

Revoking a device on the hub closes that device's open connections at once (close 1008).

### 3.3 Images: attach

An image goes up in parts, because a message is at most 1 MB:

| Field | Rule |
|---|---|
| `upload` | The client's name for this image: 1–32 characters of `A–Z a–z 0–9 _ -`. Unique per connection while held. It is only a handle; it never becomes a file name. |
| `part` | 0-based. Parts come in order, one upload at a time. A part out of order, or a part of another upload while one is open, replies `badRequest` and drops the open upload. |
| `parts` | 1–16, the same on every part. |
| `data` | Standard base64, at most 640 KiB decoded per part. |

At most 10 MiB in all per image. Each part gets a `reply`. The last part completes the upload: the hub reads the
type from the magic bytes (PNG, JPEG, HEIC, WebP; anything else replies `badRequest`), checks the pixel size from
the header (at most 12,000 px a side and 50 megapixels) before decoding, decodes the first frame, and writes a
**new** image (orientation applied, long side at most 4,096 px; PNG stays PNG, the rest become JPEG; no metadata).
Then it pushes `attached` and replies `ok`. A file that does not decode replies `badRequest`.

Limits: 4 finished uploads held per connection (a fifth drops the oldest unsent one and its file) and 8 per device
over all its connections (more: `rateLimited`); per device, 20 images and 100 MiB in 10 minutes, counted over all its
connections, before any decoding, and the written files count too (`rateLimited`). At most 4 connections per device
(a fifth `hello` gets `rateLimited` and is closed). At most 2 images are decoded at once on the hub. Unsent uploads
are deleted when the connection closes. The level is checked again after the decoding: a device downgraded or
revoked meanwhile gets `readOnly`, and the new file is deleted.

Queues: client messages waiting on one connection are capped at 64 KiB before `hello` and 4 MiB after; over it the
connection is closed (1008). A level change or a revoke on the hub closes the device's connections at once; the
client says `hello` again to learn its level. A `send` that names an unknown upload replies `badRequest` and sends nothing; uploads stay
until a `send` with them succeeds, so a refused `send` (`promptOpen`) can be repeated.

## 4. Hub to client

| `type` | Fields | When |
|---|---|---|
| `paired` | `token`, `device` (`{id, name, level}`) | After a good `pair`. The token is shown only here. |
| `welcome` | `hub` (name), `hubVersion`, `level` (`read` / `input`), `session?` (herdr session name; absent = default) | After a good `hello`. |
| `reply` | `re`, `ok`, `error?` {`code`, `message`} | Once per client message. |
| `snapshot` | `workspaces` | After `welcome`, and on every change of workspaces, tabs, panes or agents. Full list each time (it is small). |
| `status` | `pane`, `status` | An agent's status changed (cheap update between snapshots). |
| `conversation` | `pane`, `session`, `mode` (`replace` / `append` / `prepend`), `items`, `hasEarlier` | `replace` on `watch` (the tail), `append` for new items, `prepend` for `loadEarlier`. An item with a known `id` replaces the old one (tool results fill in later). |
| `screen` | `pane`, `text` | The visible screen text of a watched pane, when it changes. |
| `prompt` | `pane`, `approval?`, `question?` | The open prompt of a watched pane. Both absent = no prompt open. |
| `attached` | `upload`, `width`, `height`, `bytes` | The last `attach` part was taken: the size of the re-encoded image. Before that part's `reply`. |
| `pong` | – | Answer to `ping`. |

Error codes: `unauthorized`, `readOnly`, `stale`, `promptOpen`, `notFound`, `badRequest`, `rateLimited`, `unsupportedVersion`, `failed`. A client treats an unknown code as `failed`.

Order: the pushes a message causes come first, then its `reply` (for `hello`: `welcome`, `snapshot`, then `reply`). `ping` gets `pong`, then `reply`. A `reply` with `unauthorized` or `unsupportedVersion` is followed by a close.

## 5. Shared objects

**Workspace** `{id, label, tabs: [Tab]}`. **Tab** `{id, label, number, status, panes: [Pane]}`. **Pane** `{id, cwd, label?, agent?}`. **Agent** `{name, kind, status, session?, title}`. `status` is one of `idle`, `working`, `blocked`, `done`, `unknown`. Terminal ids stay inside the hub.

**Item** (conversation): `{id, kind, time?, …}`. `time` is ISO 8601 UTC with milliseconds. By `kind`:

| `kind` | Fields |
|---|---|
| `user` | `text` |
| `assistant` | `text` (markdown) |
| `tools` | `tools: [{symbol, text, calls: [{id, tool, summary, done, error}]}]` |
| `approval` | `approval` (below) |
| `question` | `question` (below) |
| `status` | `text` |

Tool inputs and outputs are not sent in v1 (size; the phone shows the summary).

**Approval** `{id, tool, title, command, state}`. `state`: `pending` / `resolved`.

**Question** `{id, agent, delivery, state, headers, questions, answers?}`. `delivery`: `picker` / `message`. `state`: `pending` / `answered` / `declined`. `answers`: one string per question when answered and known. Each question: `{id, header, text, multiSelect, options: [{label, detail?, recommended?}]}`.

## 6. Levels

- `read`: everything except `send`, `attach`, `approve`, `answer` (they reply `readOnly`).
- `input`: all. Set per device on the hub, never by the client. The app-wide "Allow input" setting applies on top: off means `readOnly` for every device.

## 7. Versioning

- Additive changes (a new optional field, a new push type that old clients may skip after `welcome`) keep `v: 1`. Clients ignore unknown fields.
- A changed meaning or a removed field is `v: 2`.
- The fixtures are the contract. A change to a fixture is a protocol change and needs a spec change in the same commit.
