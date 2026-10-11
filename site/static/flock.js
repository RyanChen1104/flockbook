// Footer flock: the app icon's small arrowheads drift as boids, settle into a V, hold, break up.
// Drawn as ASCII on a monospace grid (default) or as the icon's arrowheads (?flock=dots).
// Paused offscreen or hidden; one static frame (the V) for reduced motion. No libraries.
(() => {
	const cv = document.querySelector('.flock');
	if (!cv) return;
	const g = cv.getContext('2d');
	const still = matchMedia('(prefers-reduced-motion: reduce)');
	const dark = matchMedia('(prefers-color-scheme: dark)');
	const ascii = new URLSearchParams(location.search).get('flock') !== 'dots';
	const N = 11, CYCLE = 18;
	const PUSH = 420, PT = 1.3; // break-up push: peak accel (px/s^2) and how long it lasts (s)
	let W = 0, H = 0, GAP = 24, K = 0.2, dpr = 1, on = false, raf = 0, last = 0, t = 0, placed = false, tb = -9;
	const birds = Array.from({ length: N }, (_, i) => ({ x: 0, y: 0, vx: 0, vy: 0, s: i, h: 0, a: i, ux: 0, uy: 0 }));

	// Slot k of the V: 0 is the leader, then alternate wings, one step back each pair.
	const slot = (k, cx, cy) => {
		const d = (k + 1) >> 1, side = k % 2 ? -1 : 1;
		return [cx - d * GAP, cy + side * d * GAP * 0.55];
	};
	const ease = (x) => x * x * (3 - 2 * x);
	// Formation weight over one cycle: drift, ease in, hold, ease out (0.9 s) while the burst pushes.
	const weight = (p) =>
		p < 0.3 ? 0 : p < 0.5 ? ease((p - 0.3) / 0.2) : p < 0.85 ? 1 : p < 0.9 ? 1 - ease((p - 0.85) / 0.05) : 0;

	function seed() {
		for (const b of birds) {
			b.x = Math.random() * W;
			b.y = 40 + Math.random() * (H - 80);
			b.a = (Math.random() - 0.5) * 1.2;
			b.vx = Math.cos(b.a) * 30;
			b.vy = Math.sin(b.a) * 30;
			b.h = b.a;
		}
	}
	function settle() {
		const cx = W / 2 + 2.5 * GAP, cy = H / 2;
		birds.forEach((b, k) => {
			[b.x, b.y] = slot((b.s = k), cx, cy);
			b.vx = 30; b.vy = 0; b.h = 0;
		});
	}

	// Once per settle: the front bird leads, the rest take slots by distance behind it;
	// a pair of one depth takes wings by height, so they never cross.
	function assign() {
		const order = birds.map((b, i) => i).sort((i, j) => birds[j].x - birds[i].x);
		for (let k = 1; k < N - 1; k += 2)
			if (birds[order[k]].y > birds[order[k + 1]].y) [order[k], order[k + 1]] = [order[k + 1], order[k]];
		order.forEach((i, rank) => (birds[i].s = rank));
		placed = true;
	}

	// Break-up: each bird picks a direction, forward and away from the centre line; step() pushes
	// it there with a force that rises and falls over PT seconds (no velocity jump).
	function burst(cy) {
		placed = false; tb = t;
		for (const b of birds) {
			const a = Math.atan2(b.y - cy, GAP * 1.2) + (Math.random() - 0.5) * 1.6;
			const m = 0.7 + Math.random() * 0.6;
			b.ux = Math.cos(a) * m; b.uy = Math.sin(a) * m * 0.6;
			b.a = a;
		}
	}

	function step(dt) {
		t += dt;
		const p = (t % CYCLE) / CYCLE, w = weight(p), f = 1 - w;
		const cx = W / 2 + 2.5 * GAP + Math.sin(t * 0.3) * 40, cy = H / 2 + Math.sin(t * 0.7) * 8;
		if (p >= 0.85 && placed) burst(cy);
		else if (w && p < 0.85 && !placed) assign();
		// Push profile u(1-u)^2, scaled so its peak is PUSH: zero at both ends, peak at a third.
		const u = (t - tb) / PT, push = u < 1 ? PUSH * 6.75 * u * (1 - u) ** 2 : 0;
		const R = GAP * 0.6 + f * (110 - GAP * 0.6); // personal space: wide while drifting
		for (const b of birds) {
			let ax = b.ux * push, ay = b.uy * push, n = 0, mx = 0, my = 0, px = 0, py = 0;
			for (const o of birds) {
				if (o === b) continue;
				const dx = o.x - b.x, dy = o.y - b.y, d = Math.hypot(dx, dy);
				if (d < 120) { n++; mx += o.vx; my += o.vy; px += dx; py += dy; }
				// Separation grows smoothly as birds close in.
				if (d < R && d > 0) { const k = ((1 - d / R) ** 2 * 260) / d; ax -= dx * k; ay -= dy * k; }
			}
			const c = f * Math.min(1, 60 / (Math.hypot(b.vx, b.vy) || 1)); // darting: ignore the flock
			if (n) {
				ax += c * ((mx / n - b.vx) * 0.25 + (px / n) * 0.03);
				ay += c * ((my / n - b.vy) * 0.25 + (py / n) * 0.03);
			}
			// Wander: each bird drifts its own way, so the group spreads across the footer.
			b.a += (Math.random() - 0.5) * 4 * Math.sqrt(dt);
			ax += f * 30 * Math.cos(b.a);
			ay += f * 18 * Math.sin(b.a);
			// Soft walls top and bottom: a spring that grows with depth, plus damping. No bounce.
			const m = 36;
			if (b.y < m) ay += (m - b.y) * 14 - Math.min(0, b.vy) * 3;
			if (b.y > H - m) ay -= (b.y - H + m) * 14 + Math.max(0, b.vy) * 3;
			// Spring to the formation slot.
			const [tx, ty] = slot(b.s, cx, cy);
			ax += w * ((tx - b.x) * 8 - b.vx * 4.5);
			ay += w * ((ty - b.y) * 8 - b.vy * 4.5);
			b.vx += ax * dt; b.vy += ay * dt;
			// Above cruise, drag eases speed down; below a floor, a gentle nudge keeps it flying.
			const sp = Math.hypot(b.vx, b.vy), cruise = 60;
			if (sp > cruise) { const k = Math.max(cruise / sp, Math.exp(-1.1 * dt)); b.vx *= k; b.vy *= k; }
			else if (f && sp < 24) { b.vx += (b.vx / (sp || 1)) * 40 * dt; b.vy += (b.vy / (sp || 1)) * 40 * dt; }
			const ox = b.x, oy = b.y;
			b.x += b.vx * dt; b.y += b.vy * dt;
			if (b.x < -30) b.x += W + 60; else if (b.x > W + 30) b.x -= W + 60;
			// Turn toward the flight direction at a bounded rate, never snapping.
			const dh = Math.atan2(b.vy, b.vx + w * 80) - b.h;
			const turn = Math.atan2(Math.sin(dh), Math.cos(dh)) * Math.min(1, dt * 7);
			b.h += Math.max(-5 * dt, Math.min(5 * dt, turn));
			if (ascii) trail(ox, oy, b.x, b.y);
		}
		if (ascii) for (let i = 0; i < field.length; i++) field[i] *= Math.exp(-2.4 * dt);
	}

	// ASCII: a grid of cells; each bird is a chevron of glyphs, its path leaves a fading density trail.
	const FONT = 13, RAMP = ' .·:-=+*#';
	let cw = 8, ch = 16, cols = 0, rows = 0, field = new Float32Array(0), ink = {};
	function trail(x0, y0, x1, y1) {
		if (Math.abs(x1 - x0) > W / 2) return; // wrapped
		const n = Math.ceil(Math.hypot(x1 - x0, y1 - y0) / (cw / 2)) || 1;
		for (let i = 1; i <= n; i++) {
			const c = Math.floor((x0 + ((x1 - x0) * i) / n) / cw), r = Math.floor((y0 + ((y1 - y0) * i) / n) / ch);
			if (c >= 0 && c < cols && r >= 0 && r < rows) field[r * cols + c] = Math.min(1, field[r * cols + c] + 0.22);
		}
	}
	// Glyph for a line through a cell at angle a (screen y points down).
	const line = (a) => '-\\|/'[Math.round((((a % Math.PI) + Math.PI) % Math.PI) / (Math.PI / 4)) % 4];
	const head = (a) => '>v<^'[Math.round(Math.atan2(Math.sin(a) * 1.6, Math.cos(a)) / (Math.PI / 2)) & 3];
	function tokens() {
		const s = typeof getComputedStyle === 'function' ? getComputedStyle(document.documentElement) : null;
		const v = (n, d) => (s && s.getPropertyValue(n).trim()) || d;
		const dk = dark.matches;
		ink = {
			fg: v('--fg', dk ? '#f5f5f7' : '#1d1d1f'),
			bird: v('--fg-2', dk ? '#a1a1a6' : '#6e6e73'),
			trail: v('--dot', dk ? '#48484c' : '#c7c7cc'),
			lead: v('--accent', dk ? '#3b9bff' : '#0066d6')
		};
	}
	function drawAscii() {
		g.setTransform(dpr, 0, 0, dpr, 0, 0);
		g.clearRect(0, 0, W, H);
		// Cell index -> [glyph, colour, rank]: birds win over trails, the leader wins over all.
		const cells = new Map();
		const put = (c, r, glyph, colour, rank) => {
			if (c < 0 || c >= cols || r < 0 || r >= rows) return;
			const i = r * cols + c, o = cells.get(i);
			if (!o || o[2] < rank) cells.set(i, [glyph, colour, rank]);
		};
		for (let i = 0; i < field.length; i++) {
			const v = field[i];
			if (v > 0.08) put(i % cols, (i / cols) | 0, RAMP[Math.min(RAMP.length - 1, 1 + ((v * 5) | 0))], ink.trail, 0);
		}
		for (const b of birds) {
			const lead = !b.s, col = lead ? ink.lead : ink.bird, s = (lead ? 1.35 : 1) * K * 1.4;
			// The icon's arrowhead, tip forward: wings run back and out from the tip.
			const fx = Math.cos(b.h), fy = Math.sin(b.h), tx = b.x + fx * 28 * s, ty = b.y + fy * 28 * s;
			for (const side of [-1, 1]) {
				const wx = -fx * 40 * s - fy * 50 * s * side, wy = -fy * 40 * s + fx * 50 * s * side;
				const glyph = line(Math.atan2(wy, wx)), steps = Math.max(1, Math.round(Math.hypot(wx, wy) / (cw * 0.9)));
				for (let k = 1; k <= steps; k++)
					put(Math.floor((tx + (wx * k) / steps) / cw), Math.floor((ty + (wy * k) / steps) / ch), glyph, col, lead ? 3 : 1);
			}
			put(Math.floor(tx / cw), Math.floor(ty / ch), head(b.h), lead ? ink.lead : ink.fg, lead ? 4 : 2);
		}
		g.font = `${FONT}px ui-monospace, 'SF Mono', Menlo, monospace`;
		g.textBaseline = 'middle';
		g.textAlign = 'center';
		const ox = (W - cols * cw) / 2, oy = (H - rows * ch) / 2;
		for (const [i, [glyph, colour]] of cells) {
			if (glyph === ' ') continue;
			g.fillStyle = colour;
			// Snap to device pixels so glyphs stay crisp.
			const x = Math.round((ox + ((i % cols) + 0.5) * cw) * dpr) / dpr;
			const y = Math.round((oy + (((i / cols) | 0) + 0.5) * ch) * dpr) / dpr;
			g.fillText(glyph, x, y);
		}
	}

	function drawDots() {
		const [l, r] = dark.matches ? ['#98989d', '#5e5e63'] : ['#8e8e93', '#3a3a3c'];
		g.setTransform(dpr, 0, 0, dpr, 0, 0);
		g.clearRect(0, 0, W, H);
		for (const b of birds) {
			const k = b.s ? K : K * 1.35;
			g.setTransform(dpr * k, 0, 0, dpr * k, b.x * dpr, b.y * dpr);
			g.rotate(b.h + Math.PI / 2);
			// The icon's small arrowhead: two facets around a notch, tip at (0, -28).
			g.fillStyle = l; g.beginPath(); g.moveTo(-50, 12); g.lineTo(0, -28); g.lineTo(0, -6); g.fill();
			g.fillStyle = r; g.beginPath(); g.moveTo(0, -28); g.lineTo(50, 12); g.lineTo(0, -6); g.fill();
		}
	}
	const draw = () => (ascii ? drawAscii() : drawDots());

	function frame(now) {
		const dt = Math.min((now - last) / 1000, 1 / 30);
		last = now;
		step(dt);
		draw();
		raf = requestAnimationFrame(frame);
	}
	function run() {
		cancelAnimationFrame(raf);
		if (still.matches) { settle(); field.fill(0); draw(); return; }
		if (on && !document.hidden) { last = performance.now(); raf = requestAnimationFrame(frame); }
	}
	function size() {
		const r = cv.getBoundingClientRect();
		const fresh = !W;
		dpr = Math.min(devicePixelRatio || 1, 2);
		W = r.width; H = r.height;
		// Spread the V and size the birds to the canvas height: the wings (5 deep) fill it.
		GAP = Math.min(40, (H / 2 - 30) / 2.75);
		K = 0.2 * Math.sqrt(H / 160);
		cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
		if (ascii) {
			g.font = `${FONT}px ui-monospace, 'SF Mono', Menlo, monospace`;
			cw = g.measureText('M').width || 8;
			ch = Math.round(FONT * 1.3);
			cols = Math.floor(W / cw); rows = Math.floor(H / ch);
			field = new Float32Array(cols * rows);
			tokens();
		}
		if (fresh) seed();
		if (still.matches) settle();
		draw();
	}

	new ResizeObserver(size).observe(cv);
	new IntersectionObserver(([e]) => { on = e.isIntersecting; run(); }).observe(cv);
	document.addEventListener('visibilitychange', run);
	still.addEventListener('change', run);
	dark.addEventListener('change', () => { tokens(); draw(); });
})();
