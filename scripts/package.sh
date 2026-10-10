#!/usr/bin/env bash
# Package build/Flockbook.app into dist/Flockbook-<VERSION>.zip and .dmg.
# Run after scripts/bundle.sh (and scripts/notarize.sh, so the zipped app is stapled).
# With SIGN_ID set, the dmg is signed too (notarize it with scripts/notarize.sh <dmg>).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Flockbook.app"
VERSION="${VERSION:-0.1.0}"
[ -d "$APP" ] || { echo "missing: $APP (run scripts/bundle.sh)"; exit 1; }
mkdir -p dist
ZIP="dist/Flockbook-$VERSION.zip"
DMG="dist/Flockbook-$VERSION.dmg"
rm -f "$ZIP" "$DMG"

ditto -c -k --keepParent "$APP" "$ZIP"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Flockbook" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"
if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --timestamp -s "$SIGN_ID" "$DMG"
fi
ls -l "$ZIP" "$DMG"
