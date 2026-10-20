// Phone stills for the README and the website: the PWA on the flockbook-demo session, served by the app's own hub
// (HerdrDesk --serve-remote: headless, 127.0.0.1, a read device; nothing is sent to herdr).
//   scripts/demo-seed.sh && swift build && (cd site && npm ci) && node scripts/demo/phone-stills.mjs <out-dir>
// -> <out>/phone-<shot>-light.png and -dark.png at 390x844, pixel ratio 3.
import { spawn, execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '../..');
const out = process.argv[2] ?? 'build/phone-stills';
mkdirSync(out, { recursive: true });
if (/"CGSSessionScreenIsLocked"\s*=\s*Yes/.test(execFileSync('/usr/sbin/ioreg', ['-n', 'Root', '-d1']).toString())) {
	console.log('phone-stills: the screen is locked; not starting');
	process.exit(3);
}
const { chromium } = createRequire(join(root, 'site/package.json'))('playwright');

const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('HERDR_')));
const hub = spawn(join(root, '.build/debug/HerdrDesk'), ['--session', 'flockbook-demo', '--serve-remote'], { stdio: ['pipe', 'pipe', 'ignore'], env });
const info = await new Promise((resolve, reject) => {
	createInterface({ input: hub.stdout }).on('line', (l) => {
		if (l.startsWith('{')) resolve(JSON.parse(l));
		else if (l.includes('FAIL')) reject(new Error(l));
	});
	hub.once('exit', (c) => reject(new Error(`hub exited ${c}`)));
});
const origin = `https://127.0.0.1:${info.port}`;

let failures = 0;
const step = (n, ok) => { if (!ok) failures++; console.log(`phone-stills: ${n} ${ok ? 'ok' : 'FAIL'}`); };
const browser = await chromium.launch({ headless: true });
try {
	for (const look of ['light', 'dark']) {
		const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true,
			colorScheme: look, ignoreHTTPSErrors: true });
		const p = await ctx.newPage();
		await p.goto(origin + '/');
		await p.evaluate((t) => localStorage.setItem('flockbook.token', t), info.token);
		await p.goto(origin + '/');
		step(`${look}: agent list`, await p.waitForSelector('.list', { timeout: 10000 }).then(() => true, () => false));
		await p.waitForTimeout(1500);
		const shot = async (name) => { await p.waitForTimeout(600); await p.screenshot({ path: join(out, `phone-${name}-${look}.png`) }); };
		await shot('list');
		// A pane by its row's words: open it, wait for its conversation.
		const open = async (words, ready) => {
			// From the list, scrolled to its end so every row is drawn.
			await p.evaluate(() => { location.hash = ''; });
			await p.waitForSelector('.list', { timeout: 10000 });
			await p.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
			await p.waitForTimeout(800);
			const id = await p.evaluate((w) => [...document.querySelectorAll('button[data-pane]')].find((b) => b.innerText.includes(w))?.dataset.pane, words);
			step(`${look}: row "${words}"`, !!id);
			if (!id) return false;
			await p.evaluate((i) => { location.hash = '#pane=' + encodeURIComponent(i); }, id);
			return p.waitForFunction(ready, null, { timeout: 10000 }).then(() => true, () => false);
		};
		// Pictures: the owner's screenshot in the bubble, the agent's below it.
		if (await open('Harvest card', () => document.querySelectorAll('button.picture').length >= 2)) {
			await p.evaluate(() => { const m = document.querySelector('.msg.user'); if (m) window.scrollBy(0, m.getBoundingClientRect().top - 72); });
			step(`${look}: pictures shown`, await p.waitForFunction(() => [...document.querySelectorAll('button.picture img')]
				.filter((i) => i.complete && i.naturalWidth > 0).length >= 1, null, { timeout: 10000 }).then(() => true, () => false));
			await shot('pictures');
		}
		// Queued: the messages waiting for the agent's turn to end.
		step(`${look}: queued shown`, await open('Harvest widget', () => !!document.querySelector('.queue .queued')));
		await p.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
		await shot('queued');
		await ctx.close();
	}
} finally {
	await browser.close();
	hub.stdin.end();
}
console.log(`phone-stills: ${failures ? `FAIL x${failures}` : 'PASS'}`);
process.exit(failures ? 1 : 0);
