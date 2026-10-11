// Usage: node scripts/flock-sim.mjs static/flock.js
// Drives flock.js without a browser with fixed 60 fps frames and logs speed after the break-up.
import { readFileSync } from 'node:fs';
const src = readFileSync(process.argv[2], 'utf8');
let rafCb = null, ioCb = null, roCb = null, now = 0;
const ctx = new Proxy({}, { get: (t, k) => (k in t ? t[k] : () => {}), set: (t, k, v) => ((t[k] = v), true) });
const cv = { getContext: () => ctx, getBoundingClientRect: () => ({ width: 1440, height: 300 }), width: 0, height: 0 };
const birdsRef = [];
const g = {
	document: { querySelector: () => cv, hidden: false, addEventListener() {} },
	matchMedia: () => ({ matches: false, addEventListener() {} }),
	ResizeObserver: class { constructor(cb) { roCb = cb; } observe() { roCb(); } },
	IntersectionObserver: class { constructor(cb) { ioCb = cb; } observe() { ioCb([{ isIntersecting: true }]); } },
	requestAnimationFrame: (cb) => ((rafCb = cb), 1), cancelAnimationFrame() {},
	performance: { now: () => now }, devicePixelRatio: 1, Math
};
// Expose the birds array by patching the source.
const patched = src.replace('const birds = ', 'const birds = globalThis.__birds = ');
new Function(...Object.keys(g), patched)(...Object.values(g));
const birds = globalThis.__birds;
const stat = () => {
	const sp = birds.map((b) => Math.hypot(b.vx, b.vy));
	return `mean speed ${(sp.reduce((a, b) => a + b) / sp.length).toFixed(0)} px/s`;
};
const marks = [15.2, 15.35, 15.6, 15.9, 16.3, 16.8, 17.5, 19, 21];
let tSim = 0;
for (let i = 0; i < 60 * 22; i++) {
	now += 1000 / 60; tSim += 1 / 60;
	const cb = rafCb; rafCb = null; cb(now);
	if (marks.length && tSim >= marks[0]) console.log(`t=${marks.shift()}s  ${stat()}`);
}
