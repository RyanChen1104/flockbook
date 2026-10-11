# Flockbook website

One static page. SvelteKit with adapter-static (csr=false: no framework JS), no tracking.
Small hand-written scripts in `static/`: `carousel.js` (active dot) and `flock.js` (footer canvas:
the icon's arrowheads drift as boids, settle into a V, break up; paused offscreen; one static
frame for reduced motion). The flock lives in the footer card; without JS the card shows the
resting V as inline SVG. `node scripts/flock-sim.mjs static/flock.js` prints the drift spread and
the break-up speed and acceleration curve (canvas size via `W=` and `H=`).

```sh
npm install
npm run dev        # local dev server
npm run build      # static output in build/
npm run shots      # headless screenshots (1440 and 390 px, light and dark) in shots/;
                   # also checks 0 px horizontal overflow and that dot 3 shows slide 3
```

- Links: `src/lib/content.js` (`links.download`, `links.github`). `null` shows a disabled placeholder.
- Features carousel (CSS scroll-snap, anchor dots; `carousel.js` lights the dot of the visible slide): one slide per feature in
  `src/lib/content.js` whose `image` stem has `static/media/<stem>-light.png`. A dark `<source>`
  is added only when `<stem>-dark.png` exists at build time (`src/routes/+page.server.js`).
  Features with no still are left out. Stills are whole windows (1.5:1) and are never cropped.
- Icons: `static/flockbook-light.svg` and `static/flockbook-dark.svg`, chosen by `prefers-color-scheme`.
