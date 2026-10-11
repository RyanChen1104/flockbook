// Renders social-preview.html to shots/social-preview.png (1x, for GitHub) and @2x (for review).
// Usage (from site/): node scripts/social/render.mjs
import { chromium } from 'playwright';
import { mkdir, stat } from 'node:fs/promises';

const src = new URL('./social-preview.html', import.meta.url).href;
await mkdir('shots', { recursive: true });
const browser = await chromium.launch({ headless: true });
for (const [scale, name] of [[1, 'social-preview.png'], [2, 'social-preview@2x.png']]) {
	const page = await browser.newPage({ viewport: { width: 1280, height: 640 }, deviceScaleFactor: scale });
	await page.goto(src, { waitUntil: 'load' });
	await page.evaluate(() => Promise.all([...document.images].map((i) => i.decode())));
	await page.screenshot({ path: `shots/${name}` });
	await page.close();
	const { size } = await stat(`shots/${name}`);
	console.log(`shots/${name}  ${(size / 1024).toFixed(0)} KB${scale === 1 && size >= 1024 * 1024 ? '  (over 1 MB)' : ''}`);
}
await browser.close();
