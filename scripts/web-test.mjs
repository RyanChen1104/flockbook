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
    /** A real reload (`goto` to the same address with another hash stays in the document). */
    async reload() { await send("Page.reload", {}, sessionId); },
    /** A DevTools call on this page. */
    async cdp(method, params = {}) { return send(method, params, sessionId); },
    /** Runs `source` in every page this target loads, before the page's own scripts. */
    async onEveryLoad(source) { await send("Page.addScriptToEvaluateOnNewDocument", { source }, sessionId); },
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
    /** Puts files in a file field, as the phone's picker would. */
    async files(sel, paths) {
      const { root } = await send("DOM.getDocument", {}, sessionId);
      const { nodeId } = await send("DOM.querySelector", { nodeId: root.nodeId, selector: sel }, sessionId);
      await send("DOM.setFileInputFiles", { files: paths, nodeId }, sessionId);
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
  // Icons (the Mac app icon, scripts/pwa-icons.swift): each one in the manifest and the page's links is served as a
  // PNG of its stated size; the maskable and touch icons are opaque; the maskable artwork stays in the 80% circle.
  const icons = JSON.parse(await fresh.eval(`(async () => {
    const m = await (await fetch('/manifest.webmanifest')).json();
    const links = [...document.querySelectorAll('link[rel~=icon], link[rel=apple-touch-icon]')]
      .map((l) => ({ src: l.getAttribute('href'), sizes: l.getAttribute('sizes') || '180x180', purpose: l.rel }));
    const out = [];
    for (const i of [...m.icons.map((i) => ({ ...i, purpose: 'manifest ' + (i.purpose || 'any') })), ...links]) {
      const r = await fetch('/' + i.src);
      const blob = await r.blob();
      const bmp = await createImageBitmap(blob);
      const c = new OffscreenCanvas(bmp.width, bmp.height), g = c.getContext('2d');
      g.drawImage(bmp, 0, 0);
      const d = g.getImageData(0, 0, bmp.width, bmp.height).data;
      let opaque = true, reach = 0;
      for (let y = 0; y < bmp.height; y++) for (let x = 0; x < bmp.width; x++) {
        const o = (y * bmp.width + x) * 4;
        if (d[o + 3] < 255) opaque = false;
        if (d[o] < 150 && d[o + 3] > 200) reach = Math.max(reach, Math.hypot(x + 0.5 - bmp.width / 2, y + 0.5 - bmp.height / 2) / bmp.width);
      }
      out.push({ src: i.src, sizes: i.sizes, purpose: i.purpose, status: r.status, type: r.headers.get('content-type'), w: bmp.width, h: bmp.height, opaque, reach });
    }
    return JSON.stringify(out);
  })()`));
  check(icons.length >= 6 && icons.every((i) => i.status === 200 && i.type === "image/png" && i.sizes === `${i.w}x${i.h}`),
    `icons: every manifest and page icon is a PNG of its stated size (${icons.map((i) => `${i.src} ${i.type} ${i.w}x${i.h}`).join(", ")})`);
  check(["192x192", "512x512"].every((z) => icons.some((i) => i.purpose === "manifest any" && i.sizes === z)), "icons: manifest has 192 and 512 (any)");
  const mask = icons.find((i) => i.purpose === "manifest maskable"), touch = icons.find((i) => i.purpose === "apple-touch-icon");
  check(mask?.w === 512 && mask.opaque && mask.reach > 0.2 && mask.reach <= 0.4, `icons: maskable 512 is opaque, artwork inside the 80% circle (reach ${mask?.reach.toFixed(3)} of the side)`);
  check(touch?.w === 180 && touch.opaque, "icons: apple-touch-icon is 180 and opaque");
  check(icons.filter((i) => i.purpose === "icon").length === 2, "icons: favicon for light and dark");
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

  // Notifications: the hub has a push key, so the list offers them; the worker is /sw.js on this origin. The default
  // browser context: Chrome has no Push API in the other (incognito) contexts and logs an error there.
  const np = await page();
  pages.push(np);
  await np.goto(origin + "/");
  await np.eval("localStorage.setItem('flockbook.token', 'input-token')");
  await np.goto(origin + "/");
  check(await np.until("document.querySelector('#notify')?.textContent === 'Notify me'") === true, "push: the list offers notifications");
  const sw = await np.until("navigator.serviceWorker.getRegistration().then(r => r && (r.active ?? r.waiting ?? r.installing)?.scriptURL)", 6000);
  check(sw === origin + "/sw.js", `push: service worker registered (${sw})`);
  await np.click("#notify");
  check(await np.until("document.querySelector('.toast')?.textContent.includes('blocked')") === true && await np.eval("document.querySelector('#notify').textContent") === "Notify me",
    "push: permission not given -> says so, stays off");
  await send("Browser.grantPermissions", { permissions: ["notifications"], origin });
  await np.click("#notify");
  // The headless shell has no push service: turning on fails there and says so; a browser with one turns on.
  const pushed = await np.until("(t => t.includes('Notifications on') || t.includes('did not turn on'))(document.querySelector('.toast')?.textContent ?? '') && document.querySelector('.toast').textContent", 8000);
  check(!!pushed && !await np.eval("document.querySelector('#notify').disabled"), `push: permission given -> tries to subscribe, answers (${pushed})`);
  // The page's half with a stand-in push service: the browser's subscription goes to the hub, which keeps it (an FCM
  // endpoint, the RFC 8291 example keys); a second tap turns it off again.
  // Kept across reloads (localStorage), as a browser keeps its subscription.
  await np.onEveryLoad(`(() => {
    const ep = 'https://fcm.googleapis.com/fcm/send/web-test';
    const make = (key) => ({ endpoint: ep, options: { applicationServerKey: key },
      toJSON: () => ({ endpoint: ep, keys: { p256dh: 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4', auth: 'BTBZMqHH6r4Tts7J_aSIgg' } }),
      unsubscribe: async () => { localStorage.removeItem('fake-sub'); return true; } });
    const saved = () => { const k = localStorage.getItem('fake-sub'); return k ? make(Uint8Array.from(JSON.parse(k)).buffer) : null; };
    PushManager.prototype.getSubscription = async () => saved();
    PushManager.prototype.subscribe = async (o) => { localStorage.setItem('fake-sub', JSON.stringify([...o.applicationServerKey])); return saved(); };
    window.__sub = () => localStorage.getItem('fake-sub');
  })()`);
  await np.goto(origin + "/");
  check(await np.until("document.querySelector('#notify')?.textContent === 'Notify me'") === true, "push: reloaded, still off");
  await np.eval("document.querySelector('.toast')?.remove()");
  await np.click("#notify");
  check(await np.until("document.querySelector('#notify')?.textContent === 'Notifications on'", 6000) === true
    && (await np.eval("document.querySelector('.toast')?.textContent ?? ''")).startsWith("Notifications on"), "push: subscribed -> the hub keeps it, the button says on");
  await np.shot("list-notify");
  // `__old` marks the page before a reload, so a check never passes on the old page.
  await np.eval("window.__old = true");
  await np.goto(origin + "/");
  check(await np.until("!window.__old && document.querySelector('#notify')?.textContent === 'Notifications on'", 6000) === true, "push: reloaded -> the hub still has it (welcome pushOn), on");
  await np.click("#notify");
  check(await np.until("document.querySelector('#notify')?.textContent === 'Notify me' && window.__sub() === null", 6000) === true, "push: tapped again -> off, unsubscribed");
  // The hub no longer has it (as after Remove on the Mac) but the browser still does: the page drops its own.
  const hubKey = [...Buffer.from("BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8", "base64url")];
  await np.eval(`localStorage.setItem('fake-sub', ${JSON.stringify(JSON.stringify(hubKey))})`);
  await np.eval("window.__old = true");
  await np.goto(origin + "/");
  check(await np.until("!window.__old && !!document.querySelector('#notify') && window.__sub() === null", 6000) === true
    && await np.eval("document.querySelector('#notify').textContent") === "Notify me", "push: the hub does not have it (removed on the Mac) -> the page drops its own, off");

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
  // No bar that stays on top: the title and the input level are plain content and scroll away with the list.
  const head = "document.querySelector('.list-head')";
  check(await p.eval(`!!${head} && !document.querySelector('.list .top') && !['sticky', 'fixed'].includes(getComputedStyle(${head}).position)`) === true,
    "list: the title is not a sticky bar");
  check(await p.eval(`${head}.querySelector('h1').textContent === 'Agents' && ['Input on', 'Read only'].includes(${head}.querySelector('.level').textContent)`) === true,
    "list: title and input level still shown");
  await p.shot("list");
  await p.shot("list", true);
  // Scrolled (page-only filler rows, gone on the next render): the title has gone up with the content.
  await p.eval(`(() => { const g = document.querySelector('.list .group:last-of-type');
    for (let i = 0; i < 12; i++) { const li = document.createElement('li'); li.innerHTML = '<div class="row glass-float"><span class="row-text"><span class="row-title">Filler agent ' + (i + 1) + '</span><span class="row-sub">claude · filler</span></span></div>'; g.append(li); }
    window.scrollTo(0, 260); })()`);
  check(await p.eval(`window.scrollY > 0 && ${head}.getBoundingClientRect().bottom <= 0`) === true, "list: scrolled, the title is out of view");
  await p.shot("list-scrolled");
  await p.shot("list-scrolled", true);
  await p.eval("window.scrollTo(0, 0)");

  // Conversation with an approval.
  await p.click("[data-pane='w1:p1']");
  check(await p.until("!!document.querySelector('#allow')") === true, "approval: card with Allow");
  check(await p.eval("getComputedStyle(document.querySelector('.top')).position") === "sticky", "conversation: the back bar stays on top");
  check(await p.eval("location.hash") === "#pane=w1%3Ap1", "nav: pane in the address (back button works)");
  check(await p.eval("document.querySelector('.msg.assistant strong')?.textContent") === "src/app.ts", "conversation: markdown bold");
  check(await p.eval("document.querySelector('.msg.assistant pre code')?.textContent") === "npm run build", "conversation: code block");
  check(await p.eval("document.querySelector('.chip summary')?.textContent") === "Ran 2 commands", "conversation: tool chip");
  // Full agent markdown, as the Mac reading view shows it: rendered into a test message in the open conversation.
  const md = [
    "## Plan", "", "Some *italic*, **bold** and ~~old~~ text.", "",
    "- one", "  - nested", "- two", "", "1. first", "2. second", "",
    "| Step | Result |", "|---|:---:|", "| build | `ok` |", "| test | **2 failed** |", "",
    "1. Run it:", "   ```sh", "   npm test", "   ```", "2. Read the output.", "",
    "> quoted *line*", "", "---", "",
    "| " + Array.from({ length: 8 }, (_, i) => `column_${i}_with_a_long_unbroken_name`).join(" | ") + " |",
    "|" + "---|".repeat(8), "| " + Array.from({ length: 8 }, (_, i) => `value_${i}_that_does_not_wrap_at_all`).join(" | ") + " |", "",
    "<img src=x onerror=\"window.__xss=1\"> [bad](javascript:window.__xss=2) [ok](https://example.com/a)", "",
    "| # | 專案 | 是什麼 |", "|---|---|---|",
    "| 1 | `~/Library/Caches/ExampleApp/paste/` 裡 1 個 1-byte 的 png | 測試留下的暫存檔 |",
    "| 2 | 視窗位置 | 誤開視窗那 8 次留下的視窗位置 |",
  ].join("\n");
  await p.eval(`(async () => { const { markdown } = await import('/markdown.js');
    const d = document.createElement('div'); d.className = 'msg assistant'; d.id = 'md-test'; d.append(markdown(${JSON.stringify(md)}));
    document.querySelector('.msg.assistant').parentElement.append(d); })()`);
  const q = (s) => `document.querySelector('#md-test ${s}')`;
  check(await p.eval(`${q("h2")}?.textContent`) === "Plan", "markdown: ## heading");
  check(await p.eval(`${q("em")}?.textContent`) === "italic" && await p.eval(`${q("del")}?.textContent`) === "old", "markdown: *italic* and ~~strike~~");
  check(await p.eval(`${q("ul > li > ul > li")}?.textContent`) === "nested" && await p.eval(`document.querySelectorAll('#md-test > ul > li').length`) === 2,
    "markdown: - list with a nested item");
  check(await p.eval(`document.querySelectorAll('#md-test > ol')[0]?.children.length`) === 2, "markdown: 1. ordered list");
  check(await p.eval(`${q("table thead th")}?.textContent`) === "Step" && await p.eval(`${q("table tbody tr:last-child td:last-child strong")}?.textContent`) === "2 failed"
    && await p.eval(`getComputedStyle(${q("table tbody td:last-child")}).textAlign`) === "center", "markdown: GFM table (header, inline, alignment)");
  check(await p.eval(`document.querySelectorAll('#md-test > ol')[1]?.querySelector('li pre code')?.textContent`) === "npm test",
    "markdown: fence indented inside a list item");
  check(await p.eval(`${q("blockquote em")}?.textContent`) === "line" && await p.eval(`!!${q("hr")}`) === true, "markdown: > quote and --- rule");
  // Outside rendered tables (a "#" header cell is fine), no line still starts with # or |.
  check(await p.eval(`(() => { const c = document.querySelector('#md-test').cloneNode(true); c.querySelectorAll('.table-wrap').forEach(t => t.remove());
    document.body.append(c); const t = c.innerText; c.remove(); return !/^#|^\\|/m.test(t); })()`) === true, "markdown: no raw # or | lines left");
  check(await p.eval(`(() => { const w = document.querySelectorAll('#md-test .table-wrap')[1]; return !!w && w.scrollWidth > w.clientWidth; })()`) === true
    && await p.eval(noScroll), "markdown: a wide table scrolls in its own box, the page does not");
  check(await p.eval(`!${q("img")} && !window.__xss && [...document.querySelectorAll('#md-test a')].map(a => a.href).join() === 'https://example.com/a'`) === true,
    "markdown: HTML stays text, only http(s) links");
  // CJK and long inline code at a phone column: every cell keeps a readable width (no one-character-per-line
  // column), no row grows tall, and the table box scrolls sideways instead.
  const cjk = await p.eval(`(() => { const t = document.querySelectorAll('#md-test .table-wrap')[2]; if (!t) return null;
    return { col: document.querySelector('#md-test').clientWidth, cell: Math.min(...[...t.querySelectorAll('td:not(.short), th:not(.short)')].map(c => c.getBoundingClientRect().width)),
      row: Math.max(...[...t.querySelectorAll('tr')].map(r => r.getBoundingClientRect().height)),
      short: t.querySelector('th').getBoundingClientRect().width }; })()`);
  check(!!cjk && cjk.cell >= 96 && cjk.row <= 110 && cjk.short < 60 && await p.eval(noScroll),
    `markdown: CJK table keeps readable columns (column ${cjk?.col} px, narrowest cell ${Math.round(cjk?.cell)} px, tallest row ${Math.round(cjk?.row)} px, # column ${Math.round(cjk?.short)} px)`);
  // Hostile nesting renders (capped) instead of exhausting the stack.
  check(await p.eval(`(async () => { const { markdown } = await import('/markdown.js');
    const f = markdown('>'.repeat(20000) + ' deep\\n\\n' + '- '.repeat(20000) + 'deep');
    return f.textContent.includes('deep'); })()`) === true, "markdown: deep > and - nesting is capped");
  // Hostile input: every case renders, in bounded time and nodes (a throw would drop the whole message).
  const hostile = {
    "table 500 columns x 500 rows": "'|'.repeat(501) + '\\n' + '|-'.repeat(500) + '|\\n' + Array(500).fill('|').join('\\n')",
    "table 130k rows": "'a|b\\n-|-\\n' + Array(130000).fill('|').join('\\n')",
    "inline nesting": "'__a'.repeat(10000) + '__'.repeat(10000)",
    "__ run": "'__'.repeat(9990) + 'x'",
    "** run": "'**'.repeat(9990) + 'x'",
    "[ run": "'['.repeat(19990)",
    "delimiter row spaces": "'a|b\\n' + ' '.repeat(30000) + 'x'",
    "fence spaces": "'```' + ' '.repeat(30000) + '`'",
    "heading spaces": "'# a' + ' '.repeat(30000) + 'x'",
    "empty - item": "'-'",
    "empty 1. item": "'1.'",
    "heading closing # run": "'# ' + '#'.repeat(40000) + 'x'",
    "~ fence with U+2028": "'~'.repeat(40000) + '\\u2028'",
    "` fence with U+2028": "'`'.repeat(19990) + '\\u2028'",
    "item spaces with U+2028": "'- ' + ' '.repeat(40000) + 'x\\u2028'",
    "130k empty items": "'-\\n'.repeat(130000)",
    "200k paragraphs": "'a\\n\\n'.repeat(200000)",
    "budget edge: rules then *x*": "'---\\n'.repeat(19999) + '\\n*x*'",
    "budget edge: rules then nested": "'---\\n'.repeat(19995) + '\\n# ' + '**a *b ~~c **d**~~*'.repeat(3)",
    "table cells full of *a*": "['a|b', '-|-', ...Array(4999).fill('*a* '.repeat(100) + '|' + '*a* '.repeat(100))].join('\\n')",
  };
  for (const [name, src] of Object.entries(hostile)) {
    const r = await p.eval(`(async () => { const { markdown } = await import('/markdown.js');
      const s = ${src}, t = performance.now();
      try { const f = markdown(s); const d = document.createElement('div'); d.append(f);
        return { ms: performance.now() - t, nodes: d.querySelectorAll('*').length };
      } catch (e) { return { error: String(e) }; } })()`);
    check(!r.error && r.ms < 250 && r.nodes <= 20000,
      `markdown hostile: ${name} (${r.error ?? `${Math.round(r.ms)} ms, ${r.nodes} nodes`})`);
  }
  check(await p.eval(`(async () => { const { markdown } = await import('/markdown.js');
    const d = document.createElement('div'); d.append(markdown('-\\n- b\\n\\n1.'));
    return d.querySelectorAll('ul > li').length === 2 && d.querySelectorAll('ol > li').length === 1; })()`) === true,
    "markdown: an empty - or 1. item is a list item");
  await p.eval("document.querySelector('#md-test').scrollIntoView()");
  await p.shot("markdown");
  await p.shot("markdown", true);
  await p.eval("document.querySelectorAll('#md-test .table-wrap')[2].scrollIntoView({ block: 'center' })");
  await p.shot("markdown-end");
  await p.shot("markdown-end", true);
  await p.eval("document.querySelector('#md-test').remove()");
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

  // Images from the phone: pick, preview, remove, send in parts with progress; the hub re-encodes them.
  const imgDir = mkdtempSync(join(tmpdir(), "fb-web-img-"));
  const big = join(imgDir, "big.png"); writeFileSync(big, Buffer.alloc(11 * 1024 * 1024, 1));
  const fake = join(imgDir, "fake.png"); writeFileSync(fake, "this is not an image");
  const icon192 = join(root, "web/icon-192.png"), icon32 = join(root, "web/favicon-32.png"), icon512 = join(root, "web/icon-512.png");
  const thumbs = "document.querySelectorAll('.thumb').length";
  check(await p.eval("(() => { const f = document.querySelector('#composer-file'); return f.type === 'file' && f.accept === 'image/*' && f.multiple; })()") === true,
    "image: the attach field takes images, several at once (camera or photos)");
  await p.files("#composer-file", [icon192, icon32]);
  check(await p.until(`${thumbs} === 2`) === true, "image: two picked -> two thumbnails");
  check(await p.eval("[...document.querySelectorAll('.thumb img')].every(i => i.src.startsWith('data:image/') && i.complete && i.naturalWidth > 0)") === true,
    "image: thumbnails are data: previews (CSP), drawn");
  await p.shot("attach");
  await p.shot("attach", true);
  await p.click(".thumb-remove");
  check(await p.until(`${thumbs} === 1`) === true, "image: remove takes one off");
  await p.files("#composer-file", [big]);
  check(await p.until("document.querySelector('.toast')?.textContent.includes('over 10 MB')") === true && await p.eval(thumbs) === 1,
    "image: over 10 MB refused on the phone, with a message");
  await p.files("#composer-file", [icon512, icon512, icon512, icon512]);
  check(await p.until(`${thumbs} === 4`) === true && await p.until("document.querySelector('.toast')?.textContent.includes('At most 4')") === true,
    "image: at most 4 per message, with a message");
  check(await p.eval("document.querySelector('#composer-attach').disabled") === true, "image: attach button off at 4");
  // Watch the progress bar while it sends.
  await p.eval("window.__progress = false; new MutationObserver(() => { if (document.querySelector('#composer-progress')) window.__progress = true; }).observe(document.body, { subtree: true, childList: true })");
  await p.type("#composer-text", "look at these");
  await p.click("#composer-send");
  check(await p.until("[...document.querySelectorAll('.msg.user')].some(e => e.textContent === 'look at these [4 images 32x32 512x512 512x512 512x512]')", 8000) === true,
    "image: text + 4 images sent, re-encoded at their size");
  check(await p.eval("window.__progress") === true, "image: a progress bar while uploading");
  check(await p.until(`${thumbs} === 0 && !document.querySelector('#composer-progress')`) === true && await p.eval("document.querySelector('#composer-text').value") === "",
    "image: composer empty after send");
  await p.files("#composer-file", [icon192]);
  await p.until(`${thumbs} === 1`);
  await p.click("#composer-send");
  check(await p.until("[...document.querySelectorAll('.msg.user')].some(e => e.textContent === '[1 image 192x192]')", 8000) === true, "image: an image with no text sends");
  await p.files("#composer-file", [fake]);
  await p.until(`${thumbs} === 1`);
  await p.type("#composer-text", "fake one");
  await p.click("#composer-send");
  check(await p.until("document.querySelector('.toast')?.textContent.includes('fake.png: Not a PNG, JPEG, HEIC or WebP image.')") === true,
    "image: the hub refuses a non-image (magic bytes, not the name); the message says which");
  check(await p.eval(`${thumbs} === 1 && document.querySelector('#composer-text').value === 'fake one'`) === true, "image: after a refusal the text and image stay");
  check(![...await p.eval("[...document.querySelectorAll('.msg.user')].map(e => e.textContent)")].includes("fake one"), "image: nothing sent after a refusal");
  await p.click(".thumb-remove");
  await p.type("#composer-text", "");
  rmSync(imgDir, { recursive: true, force: true });
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

  // A Claude question read from the screen only: shown, answered on the Mac (no answer controls).
  await p.eval("location.hash = '#pane=w2%3Ap2'");
  await p.until("document.querySelector('#composer-text')?.disabled === false");
  await p.type("#composer-text", "ask me");
  await p.click("#composer-send");
  check(await p.until("(document.querySelector('.card.question')?.textContent ?? '').includes('Answer this question on the Mac.')") === true,
    "question: a screen-read question says answer on the Mac");
  check(await p.eval("!document.querySelector('#submit-answer') && !document.querySelector('.option')") === true, "question: no answer controls for it");
  await p.shot("question-mac");

  // The newest message: a conversation opens at the bottom and stays there while rows arrive, after a switch, a reload
  // and a return from the background. A reader who scrolled up stays where they are.
  const bottomGap = "Math.round(document.documentElement.scrollHeight - window.innerHeight - window.scrollY)";
  const atEnd = `${bottomGap} <= 4`;
  const grow = (session, n) => hub.stdin.write(`grow ${session} ${n}\n`);
  const rows = "document.querySelectorAll('.msg').length";
  await p.eval("location.hash = '#pane=w2%3Ap1'");
  await p.until(`${rows} > 0`);
  const before = await p.eval(rows);
  grow("s3", 30);   // the agent writes after the page opened
  await p.until(`${rows} >= ${before + 30}`);
  check(await p.until(atEnd, 2000) === true, `newest: rows that arrive after opening -> at the bottom (gap ${await p.eval(bottomGap)})`);
  grow("s3", 3);
  await p.until(`${rows} >= ${before + 33}`);
  check(await p.until(atEnd, 2000) === true, `newest: more rows while at the bottom -> still there (gap ${await p.eval(bottomGap)})`);
  await p.until("!document.querySelector('.toast')", 8000);   // an earlier check's message would cover the end
  await p.shot("newest");
  await p.shot("newest", true);
  // Scrolled up: rows arrive, the reader is not pulled back.
  await p.eval("window.dispatchEvent(new WheelEvent('wheel', { deltaY: -100 })); window.scrollTo(0, 200)");
  await new Promise((r) => setTimeout(r, 300));
  grow("s3", 3);
  await p.until(`${rows} >= ${before + 36}`);
  await new Promise((r) => setTimeout(r, 500));
  check(await p.eval("Math.round(window.scrollY)") === 200, `newest: scrolled up -> stays (y ${await p.eval("Math.round(window.scrollY)")})`);
  // Another agent, then back: each opens at its newest message.
  grow("s4", 30);
  await p.eval("location.hash = '#pane=w2%3Ap2'");
  await p.until(`${rows} >= 30`);
  check(await p.until(atEnd, 2000) === true, `newest: switch to another agent -> at the bottom (gap ${await p.eval(bottomGap)})`);
  await p.eval("location.hash = '#pane=w2%3Ap1'");
  await p.until(`${rows} >= ${before + 36}`);
  check(await p.until(atEnd, 2000) === true, `newest: back to the first agent -> at the bottom (gap ${await p.eval(bottomGap)})`);
  // Reload. From here on the page keeps its sockets where the check can close one (a dropped connection).
  await p.onEveryLoad("{ const W = WebSocket; window.__sockets = []; window.WebSocket = class extends W { constructor(...a) { super(...a); window.__sockets.push(this); } }; }");
  await p.eval("window.__loaded = true");
  await p.reload();
  await p.until("!window.__loaded && window.__sockets", 8000);
  await p.until(`${rows} >= ${before + 36}`, 8000);
  check(await p.until(atEnd, 2000) === true, `newest: reload -> at the bottom (gap ${await p.eval(bottomGap)})`);
  // The connection drops while the reader is scrolled up: the short "Not connected" screen puts the page at the top. That
  // is not the reader scrolling: back online, rows arrive and the reader is not pulled to the bottom.
  const y = "Math.round(window.scrollY)";
  await p.eval("window.dispatchEvent(new WheelEvent('wheel', { deltaY: -100 })); window.scrollTo(0, 200)");
  await new Promise((r) => setTimeout(r, 300));
  await p.eval("window.__sockets.at(-1).close()");
  await p.until("document.body.innerText.includes('Not connected')");
  await p.until(`${rows} >= ${before + 36}`, 8000);
  grow("s3", 2);
  await p.until(`${rows} >= ${before + 38}`);
  await new Promise((r) => setTimeout(r, 500));
  check(await p.eval(bottomGap) > 200, `newest: connection dropped while scrolled up -> not pulled to the bottom after it returns (gap ${await p.eval(bottomGap)}, y ${await p.eval(y)})`);
  // Pinch zoom: what the reader sees is the visual viewport. At the bottom of the page but zoomed in on its top half,
  // the newest rows are out of view: rows that arrive do not move the page.
  await p.eval("window.scrollTo(0, document.documentElement.scrollHeight)");
  await new Promise((r) => setTimeout(r, 300));
  await p.cdp("Emulation.setPageScaleFactor", { pageScaleFactor: 2 });
  await p.until("window.visualViewport.scale > 1.5");
  // The reader moves only the zoomed view (the page itself stays at its bottom: no window scroll event).
  const zoomedY = await p.eval(y);
  await p.cdp("Input.dispatchMouseEvent", { type: "mouseWheel", x: 195, y: 400, deltaX: 0, deltaY: 120 });
  await p.until("window.visualViewport.offsetTop > 50");
  const moved = await p.eval("Math.round(window.visualViewport.offsetTop)");
  await new Promise((r) => setTimeout(r, 300));
  grow("s3", 2);
  await p.until(`${rows} >= ${before + 40}`);
  await new Promise((r) => setTimeout(r, 500));
  check(moved > 50 && await p.eval(y) === zoomedY, `newest: zoomed in above the newest rows -> stays (view moved ${moved}, y ${zoomedY} -> ${await p.eval(y)})`);
  await p.cdp("Emulation.setPageScaleFactor", { pageScaleFactor: 1 });
  await p.until("window.visualViewport.scale < 1.1");
  await p.eval("window.scrollTo(0, document.documentElement.scrollHeight)");   // following again
  await new Promise((r) => setTimeout(r, 300));
  // The reader scrolls up in the same frame as the page grew (before the resize observer saw the new height): their
  // scroll counts, the page is not pulled back.
  await p.eval(`(() => { const d = document.createElement('div'); d.style.height = '600px'; document.getElementById('app').append(d);
    window.dispatchEvent(new WheelEvent('wheel', { deltaY: -300 })); window.scrollBy(0, -300); })()`);
  await new Promise((r) => setTimeout(r, 900));   // past the moment after the reader's input
  check(await p.eval(bottomGap) > 300, `newest: scrolled up while the page grew -> stays (gap ${await p.eval(bottomGap)})`);
  await p.eval("window.scrollTo(0, document.documentElement.scrollHeight)");   // following again
  await new Promise((r) => setTimeout(r, 300));
  // The scroll bar held longer than that moment, then dragged up in the frame the page grew: still the reader.
  await p.eval("document.documentElement.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))");
  await new Promise((r) => setTimeout(r, 900));
  await p.eval(`(() => { const d = document.createElement('div'); d.style.height = '600px'; document.getElementById('app').append(d);
    window.scrollBy(0, -300); })()`);
  await new Promise((r) => setTimeout(r, 900));
  check(await p.eval(bottomGap) > 300, `newest: scroll bar held, dragged up while the page grew -> stays (gap ${await p.eval(bottomGap)})`);
  await p.eval("document.documentElement.dispatchEvent(new PointerEvent('pointerup', { bubbles: true }))");
  await p.eval("window.scrollTo(0, document.documentElement.scrollHeight)");
  await new Promise((r) => setTimeout(r, 300));
  // The scroll bar let go outside the window (no pointerup reaches the page): the window losing focus ends the hold, and
  // a hold with no movement for 10 s ends by itself. Following again either way.
  const grows = "(() => { const d = document.createElement('div'); d.style.height = '400px'; document.getElementById('app').append(d); })()";
  await p.eval("document.documentElement.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true })); window.dispatchEvent(new Event('blur'))");
  await new Promise((r) => setTimeout(r, 900));
  await p.eval(grows);
  check(await p.until(atEnd, 2000) === true, `newest: scroll bar let go outside the window -> follows again (gap ${await p.eval(bottomGap)})`);
  await p.eval("document.documentElement.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))");
  await new Promise((r) => setTimeout(r, 10500));
  await p.eval(grows);
  check(await p.until(atEnd, 2000) === true, `newest: scroll bar held still for 10 s -> follows again (gap ${await p.eval(bottomGap)})`);
  // The page goes to the background and the browser moves it meanwhile (a restored page, a closed keyboard). That is not
  // the reader either: back in front, the page is at the newest message.
  await p.eval(`Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'hidden' });
    document.dispatchEvent(new Event('visibilitychange')); window.scrollTo(0, 0)`);
  await new Promise((r) => setTimeout(r, 300));
  await p.eval(`delete document.visibilityState; document.dispatchEvent(new Event('visibilitychange'))`);
  check(await p.until(atEnd, 2000) === true, `newest: back from the background -> at the bottom (gap ${await p.eval(bottomGap)})`);

  for (const x of pages) check(x.errors.length === 0, `page: no errors or CSP violations (${x.errors.join(" | ")})`);
}

