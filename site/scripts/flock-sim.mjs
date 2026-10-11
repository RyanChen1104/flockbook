// Usage: node scripts/flock-sim.mjs static/flock.js [seeds]
// Drives flock.js without a browser at a fixed 60 fps over three 18 s cycles and prints:
// - spread while drifting: mean nearest-neighbour distance and the share of birds within 40 px of another;
// - the break-up curve: peak speed, acceleration and turn rate per 0.1 s around the release.
import { readFileSync } from 'node:fs';
const src = readFileSync(process.argv[2], 'utf8');
const seeds = Number(process.argv[3] || 8);
const W = 1440, H = 300, FPS = 60, CYCLE = 18, CLOSE = 40;

function run(seed) {
	let s = seed * 2654435761 >>> 0;
	const rnd = () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296);
	let rafCb = null, ioCb = null, roCb = null, now = 0;
	const ctx = new Proxy({ measureText: () => ({ width: 7.8 }) }, { get: (t, k) => (k in t ? t[k] : () => {}), set: (t, k, v) => ((t[k] = v), true) });
	const cv = { getContext: () => ctx, getBoundingClientRect: () => ({ width: W, height: H }), width: 0, height: 0 };
	const M = Object.create(Math);
	M.random = rnd;
	const g = {
		document: { querySelector: () => cv, hidden: false, addEventListener() {} },
		matchMedia: () => ({ matches: false, addEventListener() {} }),
		ResizeObserver: class { constructor(cb) { roCb = cb; } observe() { roCb(); } },
		IntersectionObserver: class { constructor(cb) { ioCb = cb; } observe() { ioCb([{ isIntersecting: true }]); } },
		requestAnimationFrame: (cb) => ((rafCb = cb), 1), cancelAnimationFrame() {},
		performance: { now: () => now }, devicePixelRatio: 1, Math: M,
		location: { search: process.env.FLOCK_MODE ? `?flock=${process.env.FLOCK_MODE}` : '' }
	};
	// Expose the birds array by patching the source.
	const patched = src.replace('const birds = ', 'const birds = globalThis.__birds = ');
	new Function(...Object.keys(g), patched)(...Object.values(g));
	const birds = globalThis.__birds;

	const nnd = [], close = [], curve = new Map();
	let prev = birds.map((b) => ({ vx: b.vx, vy: b.vy, h: b.h ?? 0 }));
	for (let i = 1; i <= FPS * CYCLE * 3; i++) {
		now += 1000 / FPS;
		const cb = rafCb; rafCb = null; cb(now);
		const t = i / FPS, p = (t % CYCLE) / CYCLE;
		let vmax = 0, amax = 0, rmax = 0;
		birds.forEach((b, k) => {
			vmax = Math.max(vmax, Math.hypot(b.vx, b.vy));
			amax = Math.max(amax, Math.hypot(b.vx - prev[k].vx, b.vy - prev[k].vy) * FPS);
			let dh = (b.h ?? 0) - prev[k].h;
			dh = Math.atan2(Math.sin(dh), Math.cos(dh));
			rmax = Math.max(rmax, Math.abs(dh) * FPS);
		});
		prev = birds.map((b) => ({ vx: b.vx, vy: b.vy, h: b.h ?? 0 }));
		// Drift windows: the first 5 s of each cycle, after the burst has played out.
		if (t > CYCLE && p < 0.28) {
			const d = birds.map((b) => Math.min(...birds.filter((o) => o !== b).map((o) => Math.hypot(o.x - b.x, o.y - b.y))));
			nnd.push(d.reduce((a, b) => a + b) / d.length);
			close.push(d.filter((x) => x < CLOSE).length / d.length);
		}
		// Break-up curve around the release at p = 0.85, binned per 0.1 s.
		const r = (t % CYCLE) - 0.85 * CYCLE;
		if (t > CYCLE && r > -0.3 && r < 2.5) {
			const key = Math.floor(r * 10) / 10, c = curve.get(key) ?? [0, 0, 0];
			curve.set(key, [Math.max(c[0], vmax), Math.max(c[1], amax), Math.max(c[2], rmax)]);
		}
	}
	const mean = (a) => a.reduce((x, y) => x + y, 0) / a.length;
	return { nnd: mean(nnd), close: mean(close), curve };
}

const runs = Array.from({ length: seeds }, (_, i) => run(i + 1));
const avg = (f) => runs.reduce((a, r) => a + f(r), 0) / runs.length;
console.log(`drift spread over ${seeds} seeds (canvas ${W}x${H}, uniform 11 birds ~ ${(0.5 * Math.sqrt((W * H) / 11)).toFixed(0)} px):`);
console.log(`  mean nearest-neighbour distance ${avg((r) => r.nnd).toFixed(1)} px`);
console.log(`  share of birds within ${CLOSE} px of another ${(avg((r) => r.close) * 100).toFixed(1)} %`);
console.log('break-up (s from release: peak speed px/s, peak accel px/s^2, peak turn rad/s, max over seeds):');
const keys = [...runs[0].curve.keys()].sort((a, b) => a - b);
for (const k of keys) {
	const v = Math.max(...runs.map((r) => r.curve.get(k)?.[0] ?? 0));
	const a = Math.max(...runs.map((r) => r.curve.get(k)?.[1] ?? 0));
	const h = Math.max(...runs.map((r) => r.curve.get(k)?.[2] ?? 0));
	console.log(`  ${k >= 0 ? '+' : ''}${k.toFixed(1)}  ${v.toFixed(0).padStart(4)}  ${a.toFixed(0).padStart(6)}  ${h.toFixed(1).padStart(5)}  ${'#'.repeat(Math.round(v / 10))}`);
}
