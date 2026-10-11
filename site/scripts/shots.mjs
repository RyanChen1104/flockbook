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
// No-JS fallback: dots are plain anchors and still move the track.
{
	const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, javaScriptEnabled: false });
	const page = await ctx.newPage();
	await page.goto(url, { waitUntil: 'networkidle' });
	await page.locator('.dots a').nth(2).click();
	await page.waitForTimeout(800);
	const slide = await page.evaluate(() => { const t = document.querySelector('.track'); return Math.round(t.scrollLeft / t.clientWidth) + 1; });
	console.log(`no JS: dot 3 -> slide ${slide}`);
	if (slide !== 3) failed = true;
	await ctx.close();
}
await browser.close();
server.close();
process.exit(failed ? 1 : 0);
