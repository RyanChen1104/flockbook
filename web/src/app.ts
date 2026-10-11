// Flockbook PWA: pair, agent list (Needs you first), conversation, approval and question cards, composer (input only).
// Talks to the hub on the same origin (`/ws`). Plain DOM, no packages. Remote protocol v1.
import type { Answer, Approval, HubMessage, Item, Level, Pane, QuestionRequest, Status, Tab, Workspace } from "./protocol.ts";
import { inline, markdown } from "./markdown.ts";

const TOKEN_KEY = "flockbook.token";
const app = document.getElementById("app") as HTMLElement;

// --- Storage (may be blocked: private mode, cleared site data).
function load(key: string): string | null {
  try { return localStorage.getItem(key); } catch { return null; }
}
function save(key: string, value: string | null): void {
  try { value === null ? localStorage.removeItem(key) : localStorage.setItem(key, value); } catch { /* not kept */ }
}

// --- DOM helper.
type Child = Node | string | null | undefined | false;
function h<K extends keyof HTMLElementTagNameMap>(tag: K, props: Record<string, unknown> = {}, ...children: Child[]): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (v === undefined || v === null || v === false) continue;
    if (k === "class") el.className = String(v);
    else if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2), v as EventListener);
    else if (k in el && typeof v !== "string") (el as unknown as Record<string, unknown>)[k] = v;
    else el.setAttribute(k, String(v));
  }
  for (const c of children) if (c !== null && c !== undefined && c !== false) el.append(c);
  return el;
}

// --- State.
interface PaneView { session?: string; items: Item[]; hasEarlier: boolean; screen?: string; approval?: Approval; question?: QuestionRequest }
const state = {
  token: load(TOKEN_KEY),
  pairSecret: null as string | null,
  fingerprint: null as string | null,
  pairError: null as string | null,
  connected: false,
  welcomed: false,
  hub: "",
  level: "read" as Level,
  workspaces: [] as Workspace[],
  panes: new Map<string, PaneView>(),
  watching: null as string | null,
  busy: false,
  banner: null as { pane: string; text: string } | null,
  toast: null as string | null,
};

// The QR link: `#pair=<secret>&fp=<sha256>`. Read once, then removed from the address bar.
function readPairLink(): boolean {
  const params = new URLSearchParams(location.hash.slice(1));
  if (!params.get("pair")) return false;
  state.pairSecret = params.get("pair");
  state.fingerprint = params.get("fp");
  state.pairError = null;
  history.replaceState(null, "", location.pathname);
  return true;
}
readPairLink();

// --- Socket.
let ws: WebSocket | null = null;
let nextId = 1;
let retry = 0;
const waiting = new Map<string, (ok: boolean, code?: string, message?: string) => void>();

function connect(): void {
  ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`);
  const sock = ws;
  sock.addEventListener("open", () => {
    state.connected = true;
    retry = 0;
    if (state.token) hello();
    render();
  });
  sock.addEventListener("message", (e: MessageEvent<string>) => {
    let m: HubMessage;
    try { m = JSON.parse(e.data) as HubMessage; } catch { return; }
    receive(m);
  });
  sock.addEventListener("close", () => {
    if (ws !== sock) return;
    ws = null;
    state.connected = false;
    state.welcomed = false;
    for (const done of waiting.values()) done(false, "failed", "Not connected.");
    waiting.clear();
    render();
    // Reconnect while paired (1, 2, 4 … 15 s).
    if (state.token) setTimeout(connect, Math.min(15000, 1000 * 2 ** retry++));
  });
}

/** Resolves when the socket is open, or after 5 s. */
async function opened(): Promise<void> {
  for (let i = 0; i < 100 && ws?.readyState === WebSocket.CONNECTING; i++) await new Promise((r) => setTimeout(r, 50));
}

function request(msg: Record<string, unknown>): Promise<{ ok: boolean; code?: string; message?: string }> {
  return new Promise((resolve) => {
    if (!ws || ws.readyState !== WebSocket.OPEN) { resolve({ ok: false, code: "failed", message: "Not connected." }); return; }
    const id = `c${nextId++}`;
    waiting.set(id, (ok, code, message) => resolve({ ok, code, message }));
    ws.send(JSON.stringify({ v: 1, id, ...msg }));
  });
}

async function hello(): Promise<void> {
  const r = await request({ type: "hello", token: state.token, client: "flockbook-web", clientVersion: "1" });
  if (!r.ok && r.code === "unauthorized") {
    state.token = null;
    save(TOKEN_KEY, null);
    state.pairError = "This device is not paired (anymore). Pair it again from the Mac.";
    render();
    return;
  }
  if (r.ok && state.watching) await request({ type: "watch", pane: state.watching });
}

function view(pane: string): PaneView {
  let v = state.panes.get(pane);
  if (!v) { v = { items: [], hasEarlier: false }; state.panes.set(pane, v); }
  return v;
}

function receive(m: HubMessage): void {
  switch (m.type) {
    case "reply": {
      const done = waiting.get(m.re);
      waiting.delete(m.re);
      done?.(m.ok, m.error?.code, m.error?.message);
      return;
    }
    case "paired":
      state.token = m.token;
      save(TOKEN_KEY, m.token);
      state.pairSecret = null;
      state.pairError = null;
      hello();
      return;
    case "welcome":
      state.welcomed = true;
      state.hub = m.hub;
      state.level = m.level;
      break;
    case "snapshot": {
      const before = new Set(blockedPanes(state.workspaces).map((p) => p.id));
      const first = state.workspaces.length === 0;
      state.workspaces = m.workspaces;
      if (!first) {
        const fresh = blockedPanes(m.workspaces).find((p) => !before.has(p.id) && p.id !== state.watching);
        if (fresh) state.banner = { pane: fresh.id, text: `${agentName(fresh)} needs you` };
      }
      break;
    }
    case "status":
      for (const w of state.workspaces) for (const t of w.tabs) for (const p of t.panes) if (p.id === m.pane && p.agent) p.agent.status = m.status;
      break;
    case "conversation": {
      const v = view(m.pane);
      v.session = m.session;
      v.hasEarlier = m.hasEarlier;
      if (m.mode === "replace") v.items = m.items;
      else {
        const known = new Map(m.items.map((i) => [i.id, i]));
        const kept = v.items.map((i) => known.get(i.id) ?? i);
        const added = m.items.filter((i) => !v.items.some((o) => o.id === i.id));
        v.items = m.mode === "prepend" ? [...added, ...kept] : [...kept, ...added];
      }
      break;
    }
    case "screen":
      view(m.pane).screen = m.text;
      break;
    case "prompt": {
      const v = view(m.pane);
      v.approval = m.approval;
      v.question = m.question;
      break;
    }
    default:
      return;
  }
  render();
}

// --- Navigation: `#pane=<id>` is the conversation; empty is the list.
function route(): string | null {
  const p = new URLSearchParams(location.hash.slice(1)).get("pane");
  return p && p.length < 200 ? p : null;
}
async function follow(): Promise<void> {
  if (readPairLink()) { if (!state.token && !ws) connect(); render(); return; }
  const want = route();
  if (want === state.watching) { render(); return; }
  if (state.watching) request({ type: "unwatch", pane: state.watching });
  state.watching = want;
  if (state.banner && state.banner.pane === want) state.banner = null;
  render();
  if (want) { await request({ type: "watch", pane: want }); window.scrollTo(0, document.body.scrollHeight); }
}
addEventListener("hashchange", follow);
function open(pane: string): void { location.hash = `pane=${encodeURIComponent(pane)}`; }

// --- Helpers.
const order: Record<Status, number> = { blocked: 0, working: 1, done: 2, idle: 3, unknown: 4 };
const statusText: Record<Status, string> = { blocked: "Needs you", working: "Working", done: "Done", idle: "Idle", unknown: "Unknown" };
function agentPanes(ws: Workspace[]): { w: Workspace; t: Tab; p: Pane }[] {
  return ws.flatMap((w) => w.tabs.flatMap((t) => t.panes.filter((p) => p.agent).map((p) => ({ w, t, p }))));
}
function blockedPanes(ws: Workspace[]): Pane[] { return agentPanes(ws).filter((x) => x.p.agent?.status === "blocked").map((x) => x.p); }
function agentName(p: Pane): string { return p.agent ? `${p.agent.name} · ${p.agent.title || p.label || p.id}` : p.label || p.id; }
function find(pane: string): { w: Workspace; t: Tab; p: Pane } | undefined {
  for (const w of state.workspaces) for (const t of w.tabs) for (const p of t.panes) if (p.id === pane) return { w, t, p };
  return undefined;
}
function dot(s: Status): HTMLElement { return h("span", { class: `dot ${s}`, role: "img", "aria-label": statusText[s] }); }
const canInput = (): boolean => state.level === "input";
function toast(text: string): void {
  state.toast = text;
  render();
  setTimeout(() => { if (state.toast === text) { state.toast = null; render(); } }, 4000);
}
function explain(code?: string, message?: string): string {
  switch (code) {
    case "stale": return "The prompt changed on the Mac. Nothing was sent.";
    case "promptOpen": return "Answer the open prompt first.";
    case "readOnly": return "This device can only read. Turn on input for it on the Mac.";
    case "notFound": return "That agent is gone.";
    default: return message || "It did not work.";
  }
}

// --- Screens.
function render(): void {
  const count = blockedPanes(state.workspaces).length;
  document.title = count ? `(${count}) Flockbook` : "Flockbook";
  const body: Child[] = [];
  if (!state.token) body.push(pairScreen());
  else if (!state.welcomed) body.push(h("p", { class: "center muted" }, state.connected ? "Connecting…" : "Not connected. Trying again…"));
  else if (state.watching) body.push(conversationScreen(state.watching));
  else body.push(listScreen());
  if (state.banner && state.token) {
    const b = state.banner;
    body.push(h("button", { class: "banner", onclick: () => { state.banner = null; open(b.pane); } }, dot("blocked"), b.text));
  }
  if (state.toast) body.push(h("div", { class: "toast", role: "status" }, state.toast));
  // Keep the composer's text and focus across renders.
  const draft = (document.getElementById("composer-text") as HTMLTextAreaElement | null)?.value;
  const focused = document.activeElement?.id;
  app.replaceChildren(...body.filter((c): c is Node | string => !!c));
  const box = document.getElementById("composer-text") as HTMLTextAreaElement | null;
  if (box && draft !== undefined) box.value = draft;
  if (focused) document.getElementById(focused)?.focus();
}

function pairScreen(): HTMLElement {
  const name = h("input", { id: "pair-name", class: "field", value: defaultName(), maxlength: "40", autocomplete: "off", "aria-label": "Device name" });
  const words = state.pairSecret ? null
    : h("input", { id: "pair-words", class: "field", placeholder: "six words from the Mac", autocomplete: "off", autocapitalize: "none", spellcheck: "false", "aria-label": "Pairing words" });
  const go = async (): Promise<void> => {
    const secret = state.pairSecret ?? words?.value.trim() ?? "";
    if (!secret || state.busy) return;
    state.busy = true;
    state.pairError = null;
    render();
    if (!ws || ws.readyState === WebSocket.CLOSING || ws.readyState === WebSocket.CLOSED) connect();
    await opened();
    const r = await request({ type: "pair", secret, name: name.value.trim() || defaultName() });
    state.busy = false;
    if (!r.ok) {
      state.pairSecret = null;
      state.pairError = r.code === "unauthorized" ? "That code is wrong or expired. Make a new one on the Mac." : explain(r.code, r.message);
    }
    render();
  };
  return h("section", { class: "pair" },
    h("h1", {}, "Pair with your Mac"),
    h("p", { class: "muted" }, state.pairSecret
      ? "This link came from the QR code on your Mac. Name this device, then pair."
      : "On the Mac: Settings › Remote access › Pair a Device. Type the six words it shows."),
    h("label", { class: "label", for: "pair-name" }, "Device name"), name,
    words && h("label", { class: "label", for: "pair-words" }, "Code"), words,
    h("button", { id: "pair-go", class: "primary", disabled: state.busy, onclick: go }, state.busy ? "Pairing…" : "Pair"),
    state.pairError && h("p", { class: "error", role: "alert" }, state.pairError),
    state.fingerprint && h("p", { class: "fine" }, `Certificate ${state.fingerprint.slice(0, 16)}… (compare with the Mac)`),
    h("p", { class: "fine" }, "A paired device can read your agents' conversations. Input stays off until you turn it on for this device on the Mac."));
}

function defaultName(): string {
  const ua = navigator.userAgent;
  return /iPhone/.test(ua) ? "iPhone" : /iPad/.test(ua) ? "iPad" : /Android/.test(ua) ? "Android phone" : "Browser";
}

function listScreen(): HTMLElement {
  const all = agentPanes(state.workspaces);
  const needs = all.filter((x) => x.p.agent?.status === "blocked");
  const row = (x: { w: Workspace; t: Tab; p: Pane }, showWs: boolean): HTMLElement =>
    h("li", {}, h("button", { class: "row", "data-pane": x.p.id, onclick: () => open(x.p.id) },
      dot(x.p.agent!.status),
      h("span", { class: "row-text" },
        h("span", { class: "row-title" }, x.p.agent!.title || x.t.label),
        h("span", { class: "row-sub" }, [x.p.agent!.name, showWs ? x.w.label : null, x.t.label].filter(Boolean).join(" · "))),
      h("span", { class: "chev", "aria-hidden": "true" }, "›")));
  const sections: Child[] = [];
  if (needs.length) {
    sections.push(h("h2", { id: "needs-you" }, `Needs you · ${needs.length}`), h("ul", { class: "group needs" }, ...needs.map((x) => row(x, true))));
  }
  for (const w of state.workspaces) {
    const rows = all.filter((x) => x.w.id === w.id && x.p.agent?.status !== "blocked")
      .sort((a, b) => order[a.p.agent!.status] - order[b.p.agent!.status] || a.t.number - b.t.number);
    if (!rows.length) continue;
    sections.push(h("h2", {}, h("span", { class: "mono" }, w.label.slice(0, 2).toUpperCase()), w.label), h("ul", { class: "group" }, ...rows.map((x) => row(x, false))));
  }
  if (!all.length) sections.push(h("p", { class: "center muted" }, "No agents running."));
  return h("section", { class: "list" },
    h("header", { class: "top" }, h("h1", {}, "Agents"),
      h("span", { class: `level ${state.level}` }, state.level === "input" ? "Input on" : "Read only")),
    ...sections);
}

function conversationScreen(pane: string): HTMLElement {
  const where = find(pane);
  const v = view(pane);
  const title = where ? (where.p.agent?.title || where.t.label) : pane;
  const status = where?.p.agent?.status ?? "unknown";
  const head = h("header", { class: "top bar" },
    h("button", { class: "back", onclick: () => { location.hash = ""; } }, "‹ Agents"),
    h("span", { class: "bar-title" }, dot(status), h("span", {}, title)));
  const items: Child[] = [];
  if (v.hasEarlier && v.session) {
    items.push(h("button", { id: "load-earlier", class: "quiet", onclick: async (e: Event) => {
      (e.currentTarget as HTMLButtonElement).disabled = true;
      const before = v.items[0]?.id;
      await request({ type: "loadEarlier", session: v.session, before });
    } }, "Load earlier"));
  }
  for (const it of v.items) items.push(itemView(it));
  if (!v.items.length && !v.screen) items.push(h("p", { class: "center muted" }, where ? "Loading…" : "This agent is gone."));
  if (v.screen && (!v.items.length || where?.p.agent === undefined)) items.push(screenView(v.screen, true));
  else if (v.screen) items.push(screenView(v.screen, false));

  const card = v.approval ? approvalCard(pane, v.approval) : v.question ? questionCard(pane, v.question, v.items) : null;
  return h("section", { class: "conversation" }, head, h("div", { class: "items" }, ...items), card, composer(pane, !!card));
}

function itemView(it: Item): HTMLElement {
  switch (it.kind) {
    case "user": return h("div", { class: "msg user" }, h("p", {}, it.text));
    case "assistant": return h("div", { class: "msg assistant" }, markdown(it.text));
    case "status": return h("p", { class: "status-line" }, it.text);
    case "tools":
      return h("div", { class: "tools" }, ...it.tools.map((c) => h("details", { class: "chip" },
        h("summary", {}, c.text),
        h("ul", {}, ...c.calls.map((call) => h("li", { class: call.error ? "error" : call.done ? "" : "running" },
          h("span", { class: "tool" }, call.tool), " ", h("code", {}, call.summary)))))));
    case "approval": {
      const a = it.approval;
      return h("div", { class: `logged ${a.state}` }, h("span", { class: "muted" }, a.state === "pending" ? "Asks: " : "Asked: "), a.title, " ", h("code", {}, a.command));
    }
    case "question": {
      const q = it.question;
      const said = q.state === "answered" && q.answers ? ` → ${q.answers.filter(Boolean).join("; ")}` : q.state === "declined" ? " → declined" : "";
      return h("div", { class: `logged ${q.state}` }, h("span", { class: "muted" }, "Question: "), q.questions.map((x) => x.text).join(" / "), said);
    }
  }
}

function screenView(text: string, open: boolean): HTMLElement {
  return h("details", { class: "screen", open }, h("summary", {}, "Screen"), h("pre", {}, text));
}

function approvalCard(pane: string, a: Approval): HTMLElement {
  const act = async (allow: boolean): Promise<void> => {
    if (state.busy) return;
    state.busy = true;
    render();
    const r = await request({ type: "approve", pane, prompt: a.id, allow });
    state.busy = false;
    if (!r.ok) toast(explain(r.code, r.message));
    render();
  };
  return h("div", { class: "card approval", role: "group", "aria-label": "Permission request" },
    h("div", { class: "card-head" }, dot("blocked"), h("strong", {}, a.title || `${a.tool} wants to run`)),
    a.command && h("pre", { class: "command" }, a.command),
    canInput()
      ? h("div", { class: "actions" },
        h("button", { id: "deny", class: "secondary", disabled: state.busy, onclick: () => act(false) }, "Deny"),
        h("button", { id: "allow", class: "primary", disabled: state.busy, onclick: () => act(true) }, "Allow"))
      : h("p", { class: "fine" }, "Read only: answer on the Mac, or turn on input for this device."));
}

/** The prompt shows the question on screen; Claude shows one of a set at a time. The log item has all of them. */
function fullQuestion(q: QuestionRequest, items: Item[]): QuestionRequest | null {
  if (q.headers.length <= q.questions.length) return q;
  for (let i = items.length - 1; i >= 0; i--) {
    const it = items[i];
    if (it.kind !== "question" || it.question.state !== "pending") continue;
    const all = it.question.questions;
    if (all.length === q.headers.length && all.every((x, n) => x.header === q.headers[n])) return { ...q, questions: all };
  }
  return null;
}

function questionCard(pane: string, prompt: QuestionRequest, items: Item[]): HTMLElement {
  const q = fullQuestion(prompt, items);
  const head = h("div", { class: "card-head" }, dot("blocked"), h("strong", {}, "Question"));
  if (!q || q.delivery !== "picker" || !canInput()) {
    const why = !canInput() ? "Read only: answer on the Mac, or turn on input for this device."
      : !q ? `${prompt.headers.length} questions: answer them on the Mac.` : "Answer this one in the terminal.";
    return h("div", { class: "card question" }, head,
      ...prompt.questions.map((x) => h("p", {}, x.text)), h("p", { class: "fine" }, why));
  }
  const picks: Set<number>[] = q.questions.map(() => new Set<number>());
  const others: HTMLInputElement[] = [];
  const submit = h("button", { id: "submit-answer", class: "primary", disabled: true }, "Send answer");
  const ready = (): boolean => q.questions.every((_, n) => picks[n].size > 0 || others[n].value.trim() !== "");
  const blocks = q.questions.map((x, n) => {
    const other = h("input", { class: "field other", placeholder: "Other…", autocomplete: "off", "aria-label": `Other answer to: ${x.text}` });
    other.addEventListener("input", () => { submit.disabled = !ready(); });
    others.push(other);
    const opts = x.options.map((o, i) => {
      const b = h("button", { class: "option", "aria-pressed": "false", onclick: () => {
        if (!x.multiSelect) { picks[n].clear(); for (const s of b.parentElement!.children) s.setAttribute("aria-pressed", "false"); }
        picks[n].has(i) ? picks[n].delete(i) : picks[n].add(i);
        b.setAttribute("aria-pressed", String(picks[n].has(i)));
        submit.disabled = !ready();
      } }, h("span", { class: "option-label" }, inline(o.label), o.recommended ? h("span", { class: "rec" }, " Recommended") : null),
        o.detail ? h("span", { class: "option-detail" }, o.detail) : null);
      return b;
    });
    return h("fieldset", {}, h("legend", {}, x.header ? `${x.header}: ` : "", x.text),
      h("div", { class: "options" }, ...opts), other, x.multiSelect ? h("p", { class: "fine" }, "Pick one or more.") : null);
  });
  submit.addEventListener("click", async () => {
    if (state.busy || !ready()) return;
    const answers: Answer[] = q.questions.map((_, n) => {
      const other = others[n].value.trim();
      return other ? { picks: [...picks[n]].sort(), other } : { picks: [...picks[n]].sort() };
    });
    state.busy = true;
    submit.disabled = true;
    const r = await request({ type: "answer", pane, question: q.id, answers });
    state.busy = false;
    if (!r.ok) toast(explain(r.code, r.message));
    render();
  });
  return h("div", { class: "card question", role: "group", "aria-label": "Question" }, head, ...blocks, h("div", { class: "actions" }, submit));
}

function composer(pane: string, promptOpen: boolean): HTMLElement | null {
  if (!canInput() || !find(pane)?.p.agent) return null;
  const box = h("textarea", { id: "composer-text", rows: 1, placeholder: promptOpen ? "Answer the prompt first" : "Message", disabled: promptOpen, "aria-label": "Message to the agent" });
  const send = async (): Promise<void> => {
    const text = box.value.trim();
    if (!text || state.busy) return;
    state.busy = true;
    const r = await request({ type: "send", pane, text });
    state.busy = false;
    if (r.ok) box.value = "";
    else toast(explain(r.code, r.message));
    render();
  };
  box.addEventListener("keydown", (e: KeyboardEvent) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); send(); } });
  return h("form", { class: "composer", onsubmit: (e: Event) => { e.preventDefault(); send(); } },
    box, h("button", { id: "composer-send", class: "primary", type: "submit", disabled: promptOpen }, "Send"));
}

// --- Start.
render();
if (state.token || state.pairSecret) connect();
follow();
