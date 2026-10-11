// Footer flock: the app icon's small arrowheads drift as boids, settle into a V, hold, break up.
// Paused offscreen or hidden; one static frame (the V) for reduced motion. No libraries.
(() => {
	const cv = document.querySelector('.flock');
	if (!cv) return;
	const g = cv.getContext('2d');
	const still = matchMedia('(prefers-reduced-motion: reduce)');
	const dark = matchMedia('(prefers-color-scheme: dark)');
	const N = 11, CYCLE = 18;
	let W = 0, H = 0, GAP = 24, K = 0.2, dpr = 1, on = false, raf = 0, last = 0, t = 0, placed = false;
	const birds = Array.from({ length: N }, (_, i) => ({ x: 0, y: 0, vx: 0, vy: 0, s: i }));

	// Slot k of the V: 0 is the leader, then alternate wings, one step back each pair.
	const slot = (k, cx, cy) => {
		const d = (k + 1) >> 1, side = k % 2 ? -1 : 1;
		return [cx - d * GAP, cy + side * d * GAP * 0.55];
	};
	// Formation weight over one cycle: drift, ease in, hold, ease out.
	const weight = (p) => (p < 0.3 ? 0 : p < 0.5 ? (p - 0.3) / 0.2 : p < 0.85 ? 1 : 1 - (p - 0.85) / 0.15);

	function seed() {
		for (const b of birds) {
			b.x = Math.random() * W;
			b.y = 20 + Math.random() * (H - 40);
			const a = (Math.random() - 0.5) * 1.2;
			b.vx = Math.cos(a) * 30;
			b.vy = Math.sin(a) * 30;
		}
	}
	function settle() {
		const cx = W / 2 + 2.5 * GAP, cy = H / 2;
		birds.forEach((b, k) => {
			[b.x, b.y] = slot((b.s = k), cx, cy);
			b.vx = 30; b.vy = 0;
		});
	}

	// Once per settle: the bird furthest ahead leads, the rest take slots by distance behind it,
	// and each pair of the same depth takes wings by height, so the two never cross.
	function assign() {
		const order = birds.map((b, i) => i).sort((i, j) => birds[j].x - birds[i].x);
		for (let k = 1; k < N - 1; k += 2)
			if (birds[order[k]].y > birds[order[k + 1]].y) [order[k], order[k + 1]] = [order[k + 1], order[k]];
		order.forEach((i, rank) => (birds[i].s = rank));
		placed = true;
	}

	function step(dt) {
		t += dt;
		const w = weight((t % CYCLE) / CYCLE);
		const cx = W / 2 + 2.5 * GAP + Math.sin(t * 0.3) * 40, cy = H / 2 + Math.sin(t * 0.7) * 8;
		if (!w) placed = false;
		else if (!placed) assign();
		const sep = (GAP * 0.6) ** 2;
		for (const b of birds) {
			let ax = 0, ay = 0, n = 0, mx = 0, my = 0, px = 0, py = 0;
			for (const o of birds) {
				if (o === b) continue;
				const dx = o.x - b.x, dy = o.y - b.y, d2 = dx * dx + dy * dy;
				if (d2 < 3600) { n++; mx += o.vx; my += o.vy; px += dx; py += dy; }
				if (d2 < sep && d2 > 0) { ax -= (dx / d2) * 600; ay -= (dy / d2) * 600; }
			}
			const f = 1 - w;
			if (n) {
				ax += f * ((mx / n - b.vx) * 0.8 + (px / n) * 0.4);
				ay += f * ((my / n - b.vy) * 0.8 + (py / n) * 0.4);
			}
			// Soft walls.
			if (b.x < 30) ax += f * 40; if (b.x > W - 30) ax -= f * 40;
			if (b.y < 24) ay += f * 40; if (b.y > H - 24) ay -= f * 40;
			// Spring to the formation slot.
			const [tx, ty] = slot(b.s, cx, cy);
			ax += w * ((tx - b.x) * 8 - b.vx * 4.5);
			ay += w * ((ty - b.y) * 8 - b.vy * 4.5);
			b.vx += ax * dt; b.vy += ay * dt;
			const sp = Math.hypot(b.vx, b.vy), max = 60;
			if (sp > max) { b.vx *= max / sp; b.vy *= max / sp; }
			if (f && sp < 18) { b.vx += (b.vx / (sp || 1)) * 4; b.vy += (b.vy / (sp || 1)) * 4; }
			b.x += b.vx * dt; b.y += b.vy * dt;
			b.h = Math.atan2(b.vy, b.vx + w * 80);
		}
	}

	function draw() {
		const [l, r] = dark.matches ? ['#98989d', '#5e5e63'] : ['#8e8e93', '#3a3a3c'];
		g.setTransform(dpr, 0, 0, dpr, 0, 0);
		g.clearRect(0, 0, W, H);
		for (const b of birds) {
			const k = b.s ? K : K * 1.35;
			g.setTransform(dpr * k, 0, 0, dpr * k, b.x * dpr, b.y * dpr);
			g.rotate((b.h ?? 0) + Math.PI / 2);
			// The icon's small arrowhead: two facets around a notch, tip at (0, -28).
			g.fillStyle = l; g.beginPath(); g.moveTo(-50, 12); g.lineTo(0, -28); g.lineTo(0, -6); g.fill();
			g.fillStyle = r; g.beginPath(); g.moveTo(0, -28); g.lineTo(50, 12); g.lineTo(0, -6); g.fill();
		}
	}

	function frame(now) {
		const dt = Math.min((now - last) / 1000, 1 / 30);
		last = now;
		step(dt);
		draw();
		raf = requestAnimationFrame(frame);
	}
	function run() {
		cancelAnimationFrame(raf);
		if (still.matches) { settle(); draw(); return; }
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
		if (fresh) seed();
		if (still.matches) settle();
		draw();
	}

	new ResizeObserver(size).observe(cv);
	new IntersectionObserver(([e]) => { on = e.isIntersecting; run(); }).observe(cv);
	document.addEventListener('visibilitychange', run);
	still.addEventListener('change', run);
	dark.addEventListener('change', draw);
})();
