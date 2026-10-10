# Flockbook website

One static page. SvelteKit with adapter-static, no client JavaScript, no tracking.

```sh
npm install
npm run dev        # local dev server
npm run build      # static output in build/
npm run shots      # headless screenshots (1440 and 390 px, light and dark) in shots/
```

- Links: `src/lib/content.js` (`links.download`, `links.github`). `null` shows a disabled placeholder.
- Screenshots: put stills in `static/media/` and set `image` on each feature in `src/lib/content.js`.
  Placeholders use a 16:10 ratio.
- Icons: `static/flockbook-light.svg` and `static/flockbook-dark.svg`, chosen by `prefers-color-scheme`.
