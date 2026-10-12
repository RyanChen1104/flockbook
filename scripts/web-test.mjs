// Headless browser test of the phone PWA against a fake hub (HerdrKitChecks --serve-web: TLS, 127.0.0.1, no herdr).
//   swift build && node scripts/web-test.mjs [--shots <dir>]      (CHROME_HEADLESS=<path> to pick the browser)
//   node scripts/web-test.mjs --live <session>   read-only smoke run: the app's own hub (HerdrDesk --serve-remote, headless,
//                                                 127.0.0.1, a read device) on a named herdr session. Sends no input.
// Drives Chrome's headless shell over the DevTools protocol with Node's built-in WebSocket: no packages, no window.
// The browser trusts only the hub's own certificate (SPKI pin), as a paired phone does.
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, existsSync, readdirSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const shotsAt = process.argv.indexOf("--shots");
const shots = shotsAt > 0 ? process.argv[shotsAt + 1] : null;
if (shots) mkdirSync(shots, { recursive: true });

function findChrome() {
  if (process.env.CHROME_HEADLESS) return process.env.CHROME_HEADLESS;
  const cache = join(homedir(), "Library/Caches/ms-playwright");
  const dirs = existsSync(cache) ? readdirSync(cache).filter((d) => d.startsWith("chromium_headless_shell-")).sort().reverse() : [];
  for (const d of dirs) {
    for (const sub of readdirSync(join(cache, d))) {
      const p = join(cache, d, sub, "chrome-headless-shell");
      if (existsSync(p)) return p;
    }
  }
  throw new Error("no chrome-headless-shell found; pass its path");
}

let failures = 0, total = 0;
function check(ok, name) {
  total++;
  if (!ok) failures++;
  console.log(`${ok ? "ok" : "FAIL"} ${name}`);
}

// --- The fake hub.
const liveAt = process.argv.indexOf("--live");
const live = liveAt > 0 ? process.argv[liveAt + 1] : null;
// The app binary talks to the window server: never start it while the screen is locked.
if (live && /"CGSSessionScreenIsLocked"\s*=\s*Yes/.test(execFileSync("/usr/sbin/ioreg", ["-n", "Root", "-d1"]).toString())) {
  console.log("web-test: the screen is locked; the live run needs it unlocked. Nothing started.");
  process.exit(2);
}
// The herdr environment of a calling pane must not leak into the app (it would pick that session).
const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("HERDR_")));
const hub = live
  ? spawn(join(root, ".build/debug/HerdrDesk"), ["--session", live, "--serve-remote"], { stdio: ["pipe", "pipe", "ignore"], env })
  : spawn(join(root, ".build/debug/HerdrKitChecks"), ["--serve-web"], { stdio: ["pipe", "pipe", "inherit"] });
const info = await new Promise((resolve, reject) => {
  const rl = createInterface({ input: hub.stdout });
  rl.on("line", (l) => {
    if (l.startsWith("{")) resolve(JSON.parse(l));
    else if (l.includes("FAIL")) reject(new Error(l));
  });
  hub.once("exit", (c) => reject(new Error(`hub exited ${c}`)));
});
const spki = execFileSync("sh", ["-c", `/usr/bin/openssl x509 -in '${info.cert}' -pubkey -noout | /usr/bin/openssl pkey -pubin -outform der | /usr/bin/openssl dgst -sha256 -binary | base64`]).toString().trim();
const origin = `https://127.0.0.1:${info.port}`;

// --- The browser.
const profile = mkdtempSync(join(tmpdir(), "fb-web-test-"));
const chrome = spawn(findChrome(), [
  "--headless", `--user-data-dir=${profile}`, "--remote-debugging-port=0", "--no-first-run", "--no-default-browser-check",
  `--ignore-certificate-errors-spki-list=${spki}`, "--window-size=390,844", "about:blank",
], { stdio: ["ignore", "ignore", "pipe"] });
const wsURL = await new Promise((resolve, reject) => {
  const rl = createInterface({ input: chrome.stderr });
  rl.on("line", (l) => { const m = l.match(/DevTools listening on (ws:\/\/\S+)/); if (m) resolve(m[1]); });
  chrome.once("exit", (c) => reject(new Error(`chrome exited ${c}`)));
});

const cdp = new WebSocket(wsURL);
await new Promise((r) => cdp.addEventListener("open", r, { once: true }));
let nextId = 1;
const pending = new Map(), listeners = [];
cdp.addEventListener("message", (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.reject(new Error(m.error.message)) : p.resolve(m.result); }
  else for (const l of listeners) l(m);
});
function send(method, params = {}, sessionId) {
  const id = nextId++;
  cdp.send(JSON.stringify({ id, method, params, sessionId }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

/** A fresh page (own storage when `context` is new). */
async function page(context) {
  const { targetId } = await send("Target.createTarget", { url: "about:blank", browserContextId: context });
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
  const errors = [];
  listeners.push((m) => {
    if (m.sessionId !== sessionId) return;
    if (m.method === "Runtime.exceptionThrown") errors.push(m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text);
    if (m.method === "Log.entryAdded" && m.params.entry.level === "error") errors.push(m.params.entry.text);
    if (m.method === "Runtime.consoleAPICalled" && m.params.type === "error") errors.push(m.params.args.map((a) => a.value ?? a.description).join(" "));
  });
  await send("Runtime.enable", {}, sessionId);
  await send("Log.enable", {}, sessionId);
  await send("Page.enable", {}, sessionId);
  await send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 3, mobile: true }, sessionId);
  const p = {
    errors,
    async eval(expr) {
      const r = await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true }, sessionId);
      if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
      return r.result.value;
    },
    async goto(url) { await send("Page.navigate", { url }, sessionId); },
    /** Waits until `expr` is truthy; returns its value, or undefined after `ms`. */
    async until(expr, ms = 4000) {
      const end = Date.now() + ms;
      while (Date.now() < end) {
        try { const v = await p.eval(expr); if (v) return v; } catch {}
        await new Promise((r) => setTimeout(r, 50));
      }
      return undefined;
    },
    async close() { await send("Target.closeTarget", { targetId }); },
    async click(sel) { return p.eval(`(() => { const e = document.querySelector(${JSON.stringify(sel)}); if (!e || e.disabled) return false; e.click(); return true; })()`); },
    async type(sel, text) {
      return p.eval(`(() => { const e = document.querySelector(${JSON.stringify(sel)}); if (!e) return false; e.value = ${JSON.stringify(text)};
        e.dispatchEvent(new Event("input", { bubbles: true })); return true; })()`);
    },
    /** Pixel ratio: the headless shell draws backdrop-filter (the blur) only at 1. */
    async scale(dpr) { await send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: dpr, mobile: true }, sessionId); },
    async shot(name, dark = false) {
      if (!shots) return;
      await send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: dark ? "dark" : "light" }] }, sessionId);
      await new Promise((r) => setTimeout(r, 150));
      const { data } = await send("Page.captureScreenshot", { format: "png" }, sessionId);
      writeFileSync(join(shots, `${name}${dark ? "-dark" : ""}.png`), Buffer.from(data, "base64"));
    },
  };
  return p;
}
async function context() { return (await send("Target.createBrowserContext")).browserContextId; }

const text = "document.getElementById('app').innerText";
const noScroll = "document.documentElement.scrollWidth <= window.innerWidth";
const pages = [];

try {
  if (live) await liveRun();
  else await fakeRun();
} catch (e) {
  check(false, `test run: ${e.stack ?? e}`);
} finally {
  for (const x of pages) await x.close().catch(() => {});
  cdp.close();
  const gone = new Promise((r) => chrome.once("exit", r));
  chrome.kill();
  await gone;
  hub.stdin.end();
  await new Promise((r) => hub.once("exit", r));
  rmSync(profile, { recursive: true, force: true });
}
console.log(failures ? `web-test: ${failures} of ${total} FAILED` : `web-test: OK ${total} checks passed`);
process.exit(failures ? 1 : 0);

/** The real app hub, a read device: list, one conversation, no input controls. */
async function liveRun() {
  const p = await page(await context());
  pages.push(p);
  await p.goto(origin + "/");
  await p.eval(`localStorage.setItem('flockbook.token', ${JSON.stringify(info.token)})`);
  await p.goto(origin + "/");
  check(await p.until("!!document.querySelector('.list')", 8000) === true, "live: agent list after hello");
  const panes = await p.eval("[...document.querySelectorAll('[data-pane]')].map(e => e.dataset.pane)");
  check(panes.length > 0, `live: ${panes.length} agents listed`);
  check(await p.eval("document.querySelector('.level').textContent") === "Read only", "live: read device");
  check(await p.eval(noScroll), "live: no sideways scroll");
  await p.shot("live-list");
  if (panes.length) {
    await p.click(`[data-pane='${panes[0]}']`);
    check(await p.until("document.querySelectorAll('.msg, .logged, .tools, .screen').length > 0", 8000) === true, `live: ${panes[0]} shows its conversation or screen`);
    check(await p.eval("!document.querySelector('#allow') && !document.querySelector('.composer')") === true, "live: no input controls for a read device");
    check(await p.eval(noScroll), "live: conversation, no sideways scroll");
    await p.shot("live-conversation");
  }
  check(p.errors.length === 0, `live: no errors or CSP violations (${p.errors.join(" | ")})`);
}

/** The fake hub: every screen and every action. */
async function fakeRun() {
  // The page and the socket on one origin, scripts under the CSP.
  const fresh = await page(await context());
  pages.push(fresh);
  await fresh.goto(origin + "/");
  check(await fresh.until("!!document.querySelector('#pair-words')") === true, "pair: without a token the page asks for the six words");
  check(await fresh.eval("document.title") === "Flockbook", "page: title");
  check(await fresh.eval("fetch('/manifest.webmanifest').then(r => r.json()).then(m => m.name)") === "Flockbook", "page: manifest");
  await fresh.shot("pair");
  await fresh.shot("pair", true);

  // Wrong words: an error, no token.
  await fresh.type("#pair-words", "wrong words here and there now");
  await fresh.click("#pair-go");
  check(await fresh.until(`${text}.includes('wrong or expired')`) === true, "pair: wrong words -> error shown");
  check(await fresh.eval("localStorage.getItem('flockbook.token')") === null, "pair: no token kept after a failure");

  // The QR link: the secret is read from the fragment and removed from the address bar; pairing gives a read device.
  await fresh.goto(`${origin}/#pair=${info.pairSecret}&fp=${info.fingerprint}`);
  check(await fresh.until("!!document.querySelector('#pair-go') && !document.querySelector('#pair-words')") === true, "pair: QR link -> no words needed");
  check(await fresh.eval("location.hash") === "", "pair: secret removed from the address bar");
  check((await fresh.eval(text)).includes(info.fingerprint.slice(0, 16)), "pair: certificate fingerprint shown for reference");
  await fresh.type("#pair-name", "Test phone");
  await fresh.click("#pair-go");
  check(await fresh.until("!!document.querySelector('.list')") === true, "pair: paired -> agent list");
  check((await fresh.eval("localStorage.getItem('flockbook.token')"))?.length > 20, "pair: device token kept");
  check(await fresh.eval("document.querySelector('.level').textContent") === "Read only", "read: level shown as Read only");

  // A read device: cards say so, no buttons, no composer.
  await fresh.click("[data-pane='w1:p1']");
  check(await fresh.until("!!document.querySelector('.card.approval')") === true, "read: approval card shown");
  check(await fresh.eval("!document.querySelector('#allow') && !document.querySelector('#deny') && !document.querySelector('.composer')") === true,
    "read: no Allow/Deny, no composer");
  check((await fresh.eval(text)).includes("Read only"), "read: card says read only");

  // An unknown token: back to pairing with a reason.
  const gone = await page(await context());
  pages.push(gone);
  await gone.goto(origin + "/");
  await gone.eval("localStorage.setItem('flockbook.token', 'no-such-token')");
  await gone.goto(origin + "/");
  check(await gone.until(`${text}.includes('not paired')`) === true, "token: unknown token -> pair screen with a reason");
  check(await gone.eval("localStorage.getItem('flockbook.token')") === null, "token: unknown token removed");

  // An input device.
  const p = await page(await context());
  pages.push(p);
  await p.goto(origin + "/");
  await p.eval("localStorage.setItem('flockbook.token', 'input-token')");
  await p.goto(origin + "/");
  check(await p.until("!!document.querySelector('.list')") === true, "list: shown after hello");
  const order = await p.eval("[...document.querySelectorAll('[data-pane]')].map(e => e.dataset.pane)");
  check(JSON.stringify(order.slice(0, 2)) === JSON.stringify(["w1:p1", "w1:p2"]) && order.length === 4, `list: Needs you first (${order})`);
  check(await p.eval("document.querySelector('#needs-you').textContent") === "Needs you · 2", "list: Needs you count");
  check(await p.eval("document.title") === "(2) Flockbook", "list: count in the title");
  check(await p.eval("document.querySelectorAll('.dot.blocked').length") === 2 && await p.eval("document.querySelectorAll('.dot.working').length") === 1,
    "list: status shapes");
  check(await p.eval(noScroll), "list: no sideways scroll at 390 pt");
  await p.shot("list");
  await p.shot("list", true);

  // Conversation with an approval.
  await p.click("[data-pane='w1:p1']");
  check(await p.until("!!document.querySelector('#allow')") === true, "approval: card with Allow");
  check(await p.eval("location.hash") === "#pane=w1%3Ap1", "nav: pane in the address (back button works)");
  check(await p.eval("document.querySelector('.msg.assistant strong')?.textContent") === "src/app.ts", "conversation: markdown bold");
  check(await p.eval("document.querySelector('.msg.assistant pre code')?.textContent") === "npm run build", "conversation: code block");
  check(await p.eval("document.querySelector('.chip summary')?.textContent") === "Ran 2 commands", "conversation: tool chip");
  check(await p.eval("document.querySelector('.card.approval .command')?.textContent") === "npm run build", "approval: command shown");
  check(await p.eval("document.querySelector('#composer-text')?.disabled") === true, "composer: off while a prompt is open");
  check(await p.eval(noScroll), "conversation: no sideways scroll");
  await p.shot("approval");
  await p.shot("approval", true);
  await p.click("#load-earlier");
  check(await p.until("document.querySelectorAll('.msg.assistant').length === 4") === true, "conversation: Load earlier prepends older items");
  check(await p.eval("document.querySelector('.msg.assistant').textContent") === "Older message 1.", "conversation: older items first");
  await p.click("#allow");
  check(await p.until(`${text}.includes('Build passed.')`) === true, "approval: Allow -> agent goes on");
  check(await p.until("!document.querySelector('.card.approval')") === true, "approval: card gone");
  check(await p.until("document.title === '(1) Flockbook'") === true, "approval: one less needs you");

  // A question.
  await p.eval("location.hash = ''");
  await p.until("!!document.querySelector('.list')");
  await p.click("[data-pane='w1:p2']");
  check(await p.until("document.querySelectorAll('.option').length === 2") === true, "question: two options");
  check((await p.eval("document.querySelector('.option').textContent")).includes("Recommended"), "question: recommended marked");
  check(await p.eval("document.querySelector('#submit-answer').disabled") === true, "question: no answer, no send");
  await p.shot("question");
  await p.shot("question", true);
  await p.click(".option");
  check(await p.eval("document.querySelector('.option').getAttribute('aria-pressed')") === "true", "question: option picked");
  await p.click("#submit-answer");
  check(await p.until(`${text}.includes('Deploying to the chosen target.')`) === true, "question: answer sent, agent goes on");

  // Composer on an idle agent, and the in-app alert when another agent starts to wait.
  await p.eval("location.hash = '#pane=w2%3Ap2'");
  check(await p.until("document.querySelector('#composer-text')?.disabled === false") === true, "composer: on for an idle agent");
  await p.type("#composer-text", "hello from the phone");
  await p.click("#composer-send");
  check(await p.until("[...document.querySelectorAll('.msg.user')].some(e => e.textContent === 'hello from the phone')") === true, "composer: text sent and shown");
  check(await p.eval("document.querySelector('#composer-text').value") === "", "composer: cleared after send");
  await p.shot("composer");
  await p.shot("composer", true);
  // Frosted glass like the app's materials: the bar and the composer blur what scrolls under them, over a see-through fill.
  const glass = (sel) => `(() => { const c = getComputedStyle(document.querySelector(${JSON.stringify(sel)}));
    const f = c.backdropFilter || c.webkitBackdropFilter || ""; const a = /rgba\\([^)]*,\\s*([0-9.]+)\\)/.exec(c.backgroundColor);
    return f.includes("blur") && !!a && Number(a[1]) < 1; })()`;
  check(await p.eval(glass(".top")) === true && await p.eval(glass(".composer")) === true, "look: bar and composer are frosted glass");
  // Stills with text under the glass (page-only filler, gone on the next render), at pixel ratio 1: see `scale`.
  if (shots) {
    await p.scale(1);
    await p.eval(`(() => { const items = document.querySelector(".items");
      for (let i = 0; i < 14; i++) { const d = document.createElement("div"); d.className = "msg assistant"; d.textContent = "Filler line " + (i + 1) + " scrolls under the frosted bar and the composer."; items.prepend(d); }
      window.scrollTo(0, 240); })()`);
    await p.shot("glass");
    await p.shot("glass", true);
    await p.scale(3);
  }
  await p.type("#composer-text", "block me");
  await p.click("#composer-send");
  check(await p.until("!!document.querySelector('.banner')") === true, "alert: banner when another agent needs you");
  await p.shot("banner");
  await p.shot("banner", true);
  await p.click(".banner");
  check(await p.until("location.hash === '#pane=w2%3Ap1'") === true, "alert: banner opens that agent");

  for (const x of pages) check(x.errors.length === 0, `page: no errors or CSP violations (${x.errors.join(" | ")})`);
}

