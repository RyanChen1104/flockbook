#!/usr/bin/env bash
# Build release and wrap it into build/Flockbook.app.
# Signing: ad-hoc by default. Set SIGN_ID to a Developer ID identity for a
# hardened-runtime release build, e.g.
#   SIGN_ID="Developer ID Application: <Your Name> (<TEAMID>)" scripts/bundle.sh
# Then notarize with scripts/notarize.sh.
# Optional env: VERSION (CFBundleShortVersionString, default 0.1.0), BUILD_NUMBER (default 1),
# ARCHS (e.g. "arm64 x86_64" for a universal binary; default native only), SCRATCH_PATH (swift --scratch-path).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SP=(); [ -n "${SCRATCH_PATH:-}" ] && SP=(--scratch-path "$SCRATCH_PATH")
mkdir -p build
if [ -z "${ARCHS:-}" ]; then
  swift build -c release --product HerdrDesk ${SP[@]+"${SP[@]}"}
  BIN="$(swift build -c release --show-bin-path ${SP[@]+"${SP[@]}"})"
  EXE="$BIN/HerdrDesk"
else
  EXES=()
  for a in $ARCHS; do
    swift build -c release --product HerdrDesk --arch "$a" ${SP[@]+"${SP[@]}"}
    BIN="$(swift build -c release --arch "$a" --show-bin-path ${SP[@]+"${SP[@]}"})"
    EXES+=("$BIN/HerdrDesk")
  done
  EXE="build/HerdrDesk-universal"
  lipo -create "${EXES[@]}" -output "$EXE"
  lipo -info "$EXE"
fi

APP="build/Flockbook.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXE" "$APP/Contents/MacOS/HerdrDesk"

# Copy SwiftPM resource bundles next to the executable's resources, if any.
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done

# App icon: only when the designer's 1024px master exists.
ICON_SRC="docs/design/icon/AppIcon-1024.png"
ICON_KEY=""
if [ -f "$ICON_SRC" ]; then
  SET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$SET"
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$ICON_SRC" --out "$SET/icon_${sz}x${sz}.png" >/dev/null
    sips -z $((sz*2)) $((sz*2)) "$ICON_SRC" --out "$SET/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="  <key>CFBundleIconFile</key><string>AppIcon</string>"
  echo "icon: AppIcon.icns from $ICON_SRC"
else
  echo "icon: $ICON_SRC not found, skipped"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.mclee.flockbook</string>
  <key>CFBundleName</key><string>Flockbook</string>
  <key>CFBundleDisplayName</key><string>Flockbook</string>
  <key>NSHumanReadableCopyright</key><string>Unofficial companion for Herdr. Not affiliated with, endorsed by, or supported by Herdr, Inc.</string>
  <key>CFBundleExecutable</key><string>HerdrDesk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
$ICON_KEY
</dict>
</plist>
PLIST

if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --deep --options runtime --timestamp -s "$SIGN_ID" "$APP"
  echo "signed: $SIGN_ID (hardened runtime)"
else
  codesign --force --deep -s - "$APP"
  echo "signed: ad-hoc"
fi
codesign --verify --deep --strict "$APP"
echo "built: $APP"
