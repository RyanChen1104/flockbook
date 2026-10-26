import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
function runCase(mode, { exit = 0, lockDuring = false } = {}) {
  mkdirSync(join(root, "build"), { recursive: true });
  const dir = mkdtempSync(join(root, "build/ui-runner-test-"));
  const state = join(dir, "state"), calls = join(dir, "calls");
  writeFileSync(state, mode);
  writeFileSync(join(dir, "ioreg"), `#!/bin/sh
mode=$(cat "$SCREEN_STATE")
if [ "$mode" = locked-once ]; then printf open > "$SCREEN_STATE"; fi
if [ "$mode" = locked ] || [ "$mode" = locked-once ]; then echo '"CGSSessionScreenIsLocked"=Yes'; fi
`, { mode: 0o755 });
  writeFileSync(join(dir, "app"), `#!/bin/sh
echo run >> "$APP_CALLS"
if [ "$LOCK_DURING" = 1 ]; then printf locked > "$SCREEN_STATE"; fi
echo 'composer-test: PASS'
echo 'sendfail-test: PASS'
exit "$APP_EXIT"
`, { mode: 0o755 });
  try {
    const result = spawnSync("/bin/bash", ["scripts/ui-checks.sh", "offline", join(dir, "out")], {
      cwd: root, encoding: "utf8", timeout: 6000,
      env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, BIN: join(dir, "app"), ONLY: "composer,sendfail",
        UI_CHECK_TIMEOUT: "1", SCREEN_STATE: state, APP_CALLS: calls, APP_EXIT: String(exit), LOCK_DURING: lockDuring ? "1" : "0" },
    });
    assert.ifError(result.error);
    return { ...result, calls: existsSync(calls) ? readFileSync(calls, "utf8").trim().split("\n").length : 0 };
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

test("a locked screen skips every selected check without launching the app", () => {
  const r = runCase("locked");
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.calls, 0);
  assert.equal((r.stdout.match(/SKIP/g) ?? []).length, 2);
  assert.match(r.stdout, /0\/2 passed;.*skipped: 2/);
});
test("the runner checks each item again after the screen unlocks", () => {
  const r = runCase("locked-once");
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.calls, 1);
  assert.match(r.stdout, /1\/2 passed;.*skipped: 1/);
});
test("locking during a check makes its result unverified, not passed or failed", () => {
  const r = runCase("open", { lockDuring: true, exit: 1 });
  assert.equal(r.status, 0, r.stdout);
  assert.equal(r.calls, 1);
  assert.match(r.stdout, /0\/2 passed;.*skipped: 2/);
});
test("an unlocked failure still fails and never counts as skipped", () => {
  const r = runCase("open", { exit: 1 });
  assert.equal(r.status, 1, r.stdout);
  assert.equal(r.calls, 2);
  assert.match(r.stdout, /failed: composer sendfail/);
  assert.doesNotMatch(r.stdout, /skipped:/);
});
