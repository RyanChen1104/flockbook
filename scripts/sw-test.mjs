// Unit test of the PWA service worker (web/src/sw.ts) in Node: a fake worker scope, push and notificationclick
// events, no browser. Run: node scripts/sw-test.mjs
import { stripTypeScriptTypes } from "node:module";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const code = stripTypeScriptTypes(readFileSync(join(root, "web/src/sw.ts"), "utf8"), { mode: "strip" });

let failures = 0, total = 0;
function check(ok, name) {
  total++;
  if (!ok) failures++;
  console.log(`${ok ? "ok" : "FAIL"} ${name}`);
}

const scope = "https://hub.example.ts.net/";
/** A fresh worker with `windows` open; returns its listeners and what it did. */
function worker(windows = []) {
  const did = { shown: [], opened: [], focused: [], navigated: [], skipped: 0, claimed: 0 };
  const on = {};
  const self = {
    registration: { scope, showNotification: async (title, options) => { did.shown.push({ title, options }); } },
    clients: {
      matchAll: async () => windows.map((url) => ({
        url, focus: async () => { did.focused.push(url); }, navigate: async (to) => { did.navigated.push(to); },
      })),
      openWindow: async (url) => { did.opened.push(url); },
      claim: async () => { did.claimed++; },
    },
    skipWaiting: async () => { did.skipped++; },
    addEventListener: (type, f) => { on[type] = f; },
  };
  vm.runInNewContext(code, { self, URL, encodeURIComponent });
  /** Fires `type`; resolves when its waitUntil promise does. */
  async function fire(type, event) {
    let wait = Promise.resolve();
    on[type]({ ...event, waitUntil: (p) => { wait = p; } });
    await wait;
  }
  return { did, fire, on };
}
const push = (data) => ({ data: data === undefined ? null : { json: () => (typeof data === "string" ? JSON.parse(data) : data) } });

{
  const w = worker();
  check(["push", "notificationclick", "install", "activate"].every((t) => typeof w.on[t] === "function"), "sw: listens to push, notificationclick, install, activate");
  await w.fire("install", {});
  await w.fire("activate", {});
  check(w.did.skipped === 1 && w.did.claimed === 1, "sw: takes over at once (skipWaiting, clients.claim)");
}
{
  const w = worker();
  await w.fire("push", push({ title: "web-dev needs you", body: "Allow Bash?", tag: "p1:needsYou", pane: "p1" }));
  const n = w.did.shown[0];
  check(w.did.shown.length === 1 && n.title === "web-dev needs you", "push: shows the title");
  check(n?.options.body === "Allow Bash?" && n.options.tag === "p1:needsYou" && n.options.data.pane === "p1", "push: body, tag and pane");
  check(n?.options.icon === "icon-192.png", "push: the app icon");
}
{
  const w = worker();
  await w.fire("push", push());
  await w.fire("push", push("not json"));
  await w.fire("push", push(["a list"]));
  check(w.did.shown.length === 3 && w.did.shown.every((n) => n.title === "Flockbook" && n.options.body === "" && n.options.data.pane === null),
    "push: no data, bad JSON or a wrong shape still shows a notification");
}
{
  const w = worker();
  await w.fire("push", push({ title: "t".repeat(500), body: "b".repeat(500), pane: 7, tag: { x: 1 } }));
  const n = w.did.shown[0];
  check(n.title.length === 120 && n.options.body.length === 200, "push: title cut to 120, body to 200");
  check(n.options.data.pane === null && n.options.tag === undefined, "push: a pane or tag that is not text is dropped");
}
{
  const w = worker([scope + "#pane=p0"]);
  let closed = false;
  await w.fire("notificationclick", { notification: { data: { pane: "p 1" }, close: () => { closed = true; } } });
  check(closed, "click: closes the notification");
  check(w.did.focused.length === 1 && w.did.navigated[0] === scope + "#pane=p%201" && !w.did.opened.length,
    `click: an open page comes to the front and shows the agent (${w.did.navigated[0]})`);
}
{
  const w = worker(["https://other.example/"]);
  await w.fire("notificationclick", { notification: { data: { pane: null }, close() {} } });
  check(w.did.opened[0] === scope && !w.did.focused.length, "click: no page of this hub -> opens the list");
}

console.log(failures ? `sw-test: ${failures} of ${total} FAILED` : `sw-test: OK ${total} checks passed`);
process.exit(failures ? 1 : 0);
