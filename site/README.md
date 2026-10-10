# Flockbook website

One static page. SvelteKit with adapter-static, no client JavaScript, no tracking.

```sh
npm install
npm run dev        # local dev server
npm run build      # static output in build/
npm run shots      # headless screenshots (1440 and 390 px, light and dark) in shots/;
                   # also checks 0 px horizontal overflow and that dot 3 shows slide 3
```

- Links: `src/lib/content.js` (`links.download`, `links.github`). `null` shows a disabled placeholder.
- Features carousel (CSS scroll-snap, anchor dots, no script): one slide per feature in
  `src/lib/content.js` whose `image` stem has `static/media/<stem>-light.png`. A dark `<source>`
  is added only when `<stem>-dark.png` exists at build time (`src/routes/+page.server.js`).
  Features with no still are left out. Stills are whole windows (1.5:1) and are never cropped.
- Icons: `static/flockbook-light.svg` and `static/flockbook-dark.svg`, chosen by `prefers-color-scheme`.
