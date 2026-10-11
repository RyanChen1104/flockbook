#!/usr/bin/env bash
# Package build/Flockbook.app into dist/Flockbook-<VERSION>.zip and .dmg (OUT=<dir> overrides dist).
# Run after scripts/bundle.sh (and scripts/notarize.sh, so the zipped app is stapled).
# With SIGN_ID set, the dmg is signed too (notarize it with scripts/notarize.sh <dmg>).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Flockbook.app"
VERSION="${VERSION:-0.1.0}"
[ -d "$APP" ] || { echo "missing: $APP (run scripts/bundle.sh)"; exit 1; }
OUT="${OUT:-dist}"
mkdir -p "$OUT"
ZIP="$OUT/Flockbook-$VERSION.zip"
DMG="$OUT/Flockbook-$VERSION.dmg"
rm -f "$ZIP" "$DMG"

ditto -c -k --keepParent "$APP" "$ZIP"

# Installer window (background, icon positions, volume icon) via dmgbuild: it writes .DS_Store
# directly and attaches with -nobrowse, so no Finder window opens (works headless on CI).
DMGBUILD="${DMGBUILD:-}"
if [ -z "$DMGBUILD" ]; then
  VENV="build/dmg-venv"
  if [ ! -x "$VENV/bin/dmgbuild" ]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --disable-pip-version-check --require-hashes -r scripts/dmg/requirements.txt
  fi
  DMGBUILD="$VENV/bin/dmgbuild"
fi
"$DMGBUILD" -s scripts/dmg/settings.py -D app="$APP" -D icon="$APP/Contents/Resources/AppIcon.icns" "Flockbook" "$DMG"
if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --timestamp -s "$SIGN_ID" "$DMG"
fi
ls -l "$ZIP" "$DMG"
