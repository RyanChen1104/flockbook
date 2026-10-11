// Headless screenshots of the built site: 1440 and 390 px wide, light and dark.
// Usage: npm run build && npm run shots   (writes to shots/)
import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const root = new URL('../build/', import.meta.url).pathname;
const types = { '.html': 'text/html', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.webp': 'image/webp', '.js': 'text/javascript', '.css': 'text/css' };
const server = createServer(async (req, res) => {
	let path = normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname));
	if (path.endsWith('/')) path += 'index.html';
	try {
		const body = await readFile(join(root, path));
		res.writeHead(200, { 'content-type': types[extname(path)] ?? 'application/octet-stream' }).end(body);
	} catch {
		res.writeHead(404).end();
	}
}).listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const url = `http://127.0.0.1:${server.address().port}/`;

await mkdir('shots', { recursive: true });
const browser = await chromium.launch({ headless: true });
let failed = false;
for (const width of [1440, 390]) {
	for (const scheme of ['light', 'dark']) {
		const page = await browser.newPage({ viewport: { width, height: 900 }, colorScheme: scheme });
		await page.goto(url, { waitUntil: 'networkidle' });
		const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
		const dotColors = await page.evaluate(() => [...document.querySelectorAll('.dots a span')].slice(0, 2).map((s) => getComputedStyle(s).backgroundColor));
		if (dotColors[0] === dotColors[1]) { console.log('  active dot is not highlighted'); failed = true; }
		const file = `shots/site-${width}-${scheme}.png`;
		await page.screenshot({ path: file, fullPage: true });
		console.log(`${file}  horizontal overflow: ${overflow}px`);
		if (overflow > 0) failed = true;
		// Carousel: the third dot must bring the third slide into the track.
		const dots = page.locator('.dots a');
		if ((await dots.count()) >= 3) {
			await page.emulateMedia({ reducedMotion: 'reduce' });
			await dots.nth(2).click();
			await page.waitForTimeout(300);
			const slide = await page.evaluate(() => {
				const t = document.querySelector('.track');
				return Math.round(t.scrollLeft / t.clientWidth) + 1;
			});
			const current = () => page.evaluate(() => [...document.querySelectorAll('.dots a')].findIndex((a) => a.hasAttribute('aria-current')) + 1);
			const afterClick = await current();
			await page.evaluate(() => { const t = document.querySelector('.track'); t.scrollLeft = 3 * t.clientWidth; });
			await page.waitForTimeout(300);
			const afterScroll = await current();
			console.log(`  dot 3 -> slide ${slide}, active dot ${afterClick}; scroll to 4 -> active dot ${afterScroll}`);
			if (slide !== 3 || afterClick !== 3 || afterScroll !== 4) failed = true;
		}
		await page.close();
	}
}
// Footer flock: draws only while visible, about 60 fps on screen, one frame for reduced motion.
// FLOCK_FRAMES=<dir> also saves the canvas at 1 s (drifting), 11 s and 14 s (in formation).
{
	const count = () => {
		window.__draws = 0;
		const clear = CanvasRenderingContext2D.prototype.clearRect;
		CanvasRenderingContext2D.prototype.clearRect = function (...a) { window.__draws++; return clear.apply(this, a); };
	};
	const draws = (page) => page.evaluate(() => window.__draws);
	for (const [mode, reducedMotion] of [['ascii', 'no-preference'], ['ascii', 'reduce'], ['dots', 'no-preference'], ['dots', 'reduce']]) {
		const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, reducedMotion });
		await page.addInitScript(count);
		await page.goto(`${url}?flock=${mode}`, { waitUntil: 'networkidle' });
		let d = await draws(page);
		await page.waitForTimeout(1000);
		const offscreen = (await draws(page)) - d;
		await page.locator('.flock').scrollIntoViewIfNeeded();
		const shown = Date.now(); // the flock's clock starts when the canvas comes on screen
		await page.waitForTimeout(200);
		d = await draws(page);
		await page.waitForTimeout(1000);
		const onscreen = (await draws(page)) - d;
		console.log(`flock ${mode} (${reducedMotion}): draws/s offscreen ${offscreen}, on screen ${onscreen}`);
		if (offscreen > 0) failed = true;
		if (reducedMotion === 'reduce' ? onscreen > 0 : onscreen < 50) failed = true;
		const dir = process.env.FLOCK_FRAMES;
		if (dir && reducedMotion === 'no-preference' && mode === 'ascii') {
			// Seconds of flock time (approximate); FLOCK_AT overrides, e.g. FLOCK_AT=15,15.5,16.5
			const times = (process.env.FLOCK_AT ?? '1,11,14').split(',').map(Number);
			for (const at of times) {
				const wait = shown + at * 1000 - Date.now();
				if (wait > 0) await page.waitForTimeout(wait);
				await page.locator('.flock').screenshot({ path: `${dir}/flock-${at}s.png` });
			}
		}
		await page.close();
	}
}

// Flock frames for both draw modes on a fake clock (exact flock time): drifting, in the V, breaking up.
for (const mode of ['ascii', 'dots'])
	for (const width of [1440, 390])
		for (const scheme of ['light', 'dark']) {
			const page = await browser.newPage({ viewport: { width, height: 900 }, colorScheme: scheme });
			await page.clock.install();
			await page.goto(`${url}?flock=${mode}`, { waitUntil: 'networkidle' });
			await page.locator('.flock').scrollIntoViewIfNeeded();
			// The observer that starts the flock fires on a real frame, not on the fake clock.
			await page.waitForTimeout(300);
			await page.clock.runFor(100);
			let at = 0;
			for (const s of [4, 12, 16.5]) {
				await page.clock.runFor((s - at) * 1000);
				at = s;
				await page.locator('.foot').screenshot({ path: `shots/flock-${mode}-${width}-${scheme}-${s}s.png` });
			}
			await page.close();
		}

// No-JS fallback: dots are plain anchors and still move the track.
{
	const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, javaScriptEnabled: false });
	const page = await ctx.newPage();
	await page.goto(url, { waitUntil: 'networkidle' });
	await page.locator('.dots a').nth(2).click();
	await page.waitForTimeout(800);
	const slide = await page.evaluate(() => { const t = document.querySelector('.track'); return Math.round(t.scrollLeft / t.clientWidth) + 1; });
	console.log(`no JS: dot 3 -> slide ${slide}`);
	await page.locator('.foot').screenshot({ path: 'shots/flock-nojs-1440-light.png' });
	if (slide !== 3) failed = true;
	await ctx.close();
}
await browser.close();
server.close();
process.exit(failed ? 1 : 0);
