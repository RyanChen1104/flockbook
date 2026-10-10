# Flockbook app icon

V2 "gem arrowhead": one faceted arrowhead (the lead) with two small ones behind it (the flock). Black and white only. No text.

| File | What |
|---|---|
| `flockbook-light.svg` | Source of truth, light appearance. |
| `flockbook-dark.svg` | Source of truth, dark appearance. |
| `AppIcon-1024.png` | Light render. `scripts/bundle.sh` builds `AppIcon.icns` from it. |
| `AppIcon-dark-1024.png` | Dark render (reference). |
| `AppIcon.icon` | Icon Composer document: gradient fill + arrowhead layer, each with a dark specialization. `scripts/bundle.sh` compiles it into `Assets.car` (`CFBundleIconName`) when `actool` exists (Xcode; the release CI has it). Its layer SVGs in `Assets/` are cut from the two sources above (body 824 px scaled to the full 1024 canvas). |

Render: `rsvg-convert -w 1024 -h 1024 flockbook-light.svg -o AppIcon-1024.png` (same for dark).
Check the .icon headless: `ictool AppIcon.icon --export-image --output-file x.png --platform macOS --rendition Dark --width 1024 --height 1024 --scale 1` (ictool is inside Icon Composer.app).

Grid: Apple macOS template. Body 824×824 at (100,100), corner radius 185.

## Previous design (stacked cards, not used)

| File | What |
|---|---|
| `flockbook-icon.svg` / `-1024.png` | Default (light) icon. Use this one. |
| `flockbook-icon-dark.svg` / `-1024.png` | Dark variant for the macOS 26 dark icon appearance. |
| `preview-64.png` | Check sheet: 64 / 32 / 16 px on white, #f5f5f7, #1e1e1e, black. Left = light, right = dark. |
| `gen.py` | Generator. `python3 -I gen.py <out_dir>`, then `rsvg-convert -w 1024 -h 1024 x.svg -o x-1024.png`. |

Grid: Apple macOS template. Body 824×824 at (100,100), corner radius 185, drop shadow inside the 1024 canvas.

For Xcode (Icon Composer / asset catalog): the SVG layers are simple shapes, so they can be split into Icon Composer layers (background, back card, middle card, front card + arc) to get the system Liquid Glass and tinted modes.
