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
		await page.close();
	}
}
await browser.close();
server.close();
process.exit(failed ? 1 : 0);
