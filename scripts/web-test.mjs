// Headless browser test of the phone PWA against a fake hub (HerdrKitChecks --serve-web: TLS, 127.0.0.1, no herdr).
//   swift build && node scripts/web-test.mjs [path/to/chrome-headless-shell]
// Drives Chrome's headless shell over the DevTools protocol with Node's built-in WebSocket: no packages, no window.
// The browser trusts only the hub's own certificate (SPKI pin), as a paired phone does.
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, readFileSync, existsSync, readdirSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

function findChrome() {
  if (process.argv[2]) return process.argv[2];
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
const hub = spawn(join(root, ".build/debug/HerdrKitChecks"), ["--serve-web"], { stdio: ["pipe", "pipe", "inherit"] });
const info = await new Promise((resolve, reject) => {
  const rl = createInterface({ input: hub.stdout });
  rl.once("line", (l) => resolve(JSON.parse(l)));
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
  };
  return p;
}
async function context() { return (await send("Target.createBrowserContext")).browserContextId; }

const text = "document.getElementById('app').innerText";

try {
  // 3a: the page loads from the hub, scripts run under the CSP, the socket on /ws answers.
  const p = await page(await context());
  await p.goto(origin + "/");
  check(await p.until(`${text}.includes('Hub reachable')`) === true, `page: served by the hub, socket /ws reachable (${await p.eval(text)})`);
  check(await p.eval("document.title") === "Flockbook", "page: title");
  check(await p.eval("fetch('/manifest.webmanifest').then(r => r.json()).then(m => m.name)") === "Flockbook", "page: manifest");
  check(p.errors.length === 0, `page: no errors or CSP violations (${p.errors.join(" | ")})`);
  await p.close();
} catch (e) {
  check(false, `test run: ${e.stack ?? e}`);
} finally {
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
