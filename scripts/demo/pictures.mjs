// Pictures for the demo session and the phone stills: a fictional app screen (Meadow's harvest card), drawn as HTML
// and saved as PNG/JPEG in scripts/demo/pictures/. Rerun after changing the drawing; the files are committed.
//   (cd site && npm ci) && node scripts/demo/pictures.mjs
// before: the card on a small phone, the total wrapped and the chart cut off (the owner's screenshot in the demo).
// after:  the same card fixed (the agent's simulator screenshot).
import { createRequire } from 'node:module';
import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const { chromium } = createRequire(join(here, '../../site/package.json'))('playwright');
const out = join(here, 'pictures');
mkdirSync(out, { recursive: true });

const days = [['Mon', 62], ['Tue', 48], ['Wed', 80], ['Thu', 71], ['Fri', 95], ['Sat', 100], ['Sun', 57]];

function page(broken) {
	const bars = days.map(([d, h], i) => `<div class="bar${i === 5 ? ' today' : ''}"><i style="height:${h}%"></i><span>${d}</span></div>`).join('');
	return `<!doctype html><meta charset="utf-8"><style>
	* { box-sizing: border-box; margin: 0; }
	html, body { height: 100%; }
	body { font: 400 15px/1.3 -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif; color: #1c2a1f; background: #eef2ec;
		display: grid; place-items: center; }
	.screen { width: ${broken ? 300 : 340}px; padding: 18px 16px 22px; background: #f5f7f3; border-radius: 28px;
		box-shadow: 0 18px 50px rgba(30, 60, 35, .18), 0 2px 6px rgba(30, 60, 35, .08); overflow: hidden; }
	.nav { display: flex; justify-content: space-between; align-items: baseline; margin: 2px 4px 14px; }
	.nav h1 { font-size: 28px; font-weight: 700; letter-spacing: -.02em; }
	.nav span { color: #3d8b4f; font-weight: 600; font-size: 15px; }
	.card { background: #fff; border-radius: 18px; padding: 16px 16px 14px; box-shadow: 0 1px 2px rgba(0,0,0,.05); }
	.label { color: #6c7a6e; font-size: 13px; font-weight: 600; text-transform: uppercase; letter-spacing: .04em; }
	.total { display: flex; align-items: baseline; gap: 6px; margin: 4px 0 2px; ${broken ? 'flex-wrap: wrap; width: 150px;' : ''} }
	.total b { font-size: ${broken ? 54 : 44}px; font-weight: 700; letter-spacing: -.03em; line-height: 1; }
	.total em { font-style: normal; font-size: 20px; font-weight: 600; color: #6c7a6e; }
	.delta { color: #3d8b4f; font-size: 14px; font-weight: 600; }
	.chart { display: flex; gap: ${broken ? 14 : 8}px; align-items: flex-end; height: 120px; margin: 16px 0 6px;
		width: ${broken ? 360 : 'auto'}${broken ? 'px' : ''}; }
	.bar { flex: ${broken ? '0 0 34px' : '1'}; height: 100%; display: flex; flex-direction: column; justify-content: flex-end; align-items: center; gap: 6px; }
	.bar i { display: block; width: 100%; border-radius: 6px; background: #cfe3d2; }
	.bar.today i { background: linear-gradient(#5fb36f, #3d8b4f); }
	.bar span { font-size: 11px; color: #8a978c; font-weight: 600; }
	.row { display: flex; align-items: center; gap: 12px; margin-top: 12px; background: #fff; border-radius: 18px; padding: 12px 14px; }
	.dot { width: 34px; height: 34px; border-radius: 10px; background: #fdf0d8; display: grid; place-items: center; font-size: 18px; }
	.row div { min-width: 0; }
	.row b { display: block; font-size: 15px; ${broken ? 'white-space: nowrap; overflow: hidden; text-overflow: ellipsis; width: 150px;' : ''} }
	.row small { color: #6c7a6e; font-size: 13px; }
	</style>
	<div class="screen">
		<div class="nav"><h1>Harvest</h1><span>Week</span></div>
		<div class="card">
			<div class="label">Today</div>
			<div class="total"><b>1,284</b><em>kg</em></div>
			<div class="delta">▲ 12% from last Saturday</div>
			<div class="chart">${bars}</div>
		</div>
		<div class="row"><div class="dot">🧺</div><div><b>Next pickup Saturday 9:00</b><small>North barn · 14 members</small></div></div>
	</div>`;
}

const browser = await chromium.launch({ headless: true });
async function shot(broken, w, h, file, type = 'png') {
	const p = await browser.newPage({ viewport: { width: w / 2, height: h / 2 }, deviceScaleFactor: 2 });
	await p.setContent(page(broken));
	await p.screenshot({ path: join(out, file), type, ...(type === 'jpeg' ? { quality: 88 } : {}) });
	await p.close();
	console.log(file);
}
// The demo session's two (4:3), and the phone stills' three in the shapes the fake hub's test log has.
await shot(true, 1200, 900, 'card-before.png');
await shot(false, 1200, 900, 'card-after.png');
await shot(true, 1600, 1200, 'card-before-1600.png');
await shot(false, 900, 600, 'card-after-900.png');
await shot(false, 120, 80, 'card-thumb.jpg', 'jpeg');
await browser.close();
