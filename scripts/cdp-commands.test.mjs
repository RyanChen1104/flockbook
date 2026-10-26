import { test } from "node:test";
import assert from "node:assert/strict";
import { createCDPSender } from "./lib/cdp-commands.mjs";

class Socket extends EventTarget {
  sent = [];
  send(data) { this.sent.push(JSON.parse(data)); this.onSend?.(this.sent.at(-1)); }
  reply(data) { this.dispatchEvent(new MessageEvent("message", { data: JSON.stringify(data) })); }
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
// The outside bound makes a missing timeout a test failure instead of hanging this regression check.
const bounded = (promise) => Promise.race([promise.then(value => ({ value }), error => ({ error })), sleep(300).then(() => ({}))]);

test("a missing reply fails with the method and session, and removes the pending request", async () => {
  const socket = new Socket(), cdp = createCDPSender(socket, { timeoutMs: 10 });
  const result = await bounded(cdp.send("Runtime.evaluate", {}, "page-7"));
  assert.match(result.error?.message ?? "no rejection", /Runtime.evaluate.*page-7.*timed out/);
  assert.equal(cdp.pendingCount, 0);
});
test("a synchronous reply cannot arrive before request registration", async () => {
  const socket = new Socket(), cdp = createCDPSender(socket, { timeoutMs: 100 });
  socket.onSend = ({ id }) => socket.reply({ id, result: { value: 42 } });
  assert.deepEqual((await bounded(cdp.send("Runtime.evaluate"))).value, { value: 42 });
  assert.equal(cdp.pendingCount, 0);
});
test("a closed socket rejects every pending request immediately", async () => {
  const socket = new Socket(), cdp = createCDPSender(socket, { timeoutMs: 100 });
  const pending = [bounded(cdp.send("Page.navigate")), bounded(cdp.send("Runtime.evaluate"))];
  socket.dispatchEvent(new Event("close"));
  for (const result of await Promise.all(pending)) assert.match(result.error?.message ?? "no rejection", /CDP.*closed/);
  assert.equal(cdp.pendingCount, 0);
});
test("normal replies and protocol errors preserve their request identity", async () => {
  const socket = new Socket(), cdp = createCDPSender(socket, { timeoutMs: 100 });
  const first = cdp.send("Page.enable"), second = cdp.send("Missing.method");
  const failure = assert.rejects(second, /Missing.method.*unknown/);
  socket.reply({ id: 2, error: { message: "unknown" } });
  socket.reply({ id: 1, result: { enabled: true } });
  assert.deepEqual(await first, { enabled: true });
  await failure;
  assert.equal(cdp.pendingCount, 0);
});
