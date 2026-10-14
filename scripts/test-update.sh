#!/usr/bin/env bash
# End-to-end auto-update check, headless: scripts/test-update.sh <new-empty-dir>
# Builds two ad-hoc app bundles (0.0.1 build 1 and 0.0.2 build 2) signed for a throwaway EdDSA key made here with
# openssl (never the keychain, never the release key), serves an appcast for 0.0.2 on 127.0.0.1, and runs 0.0.1
# with --test-update: Sparkle must download 0.0.2, check its signature and replace the 0.0.1 bundle in place.
# Then a tampered archive and an edited (re-signed by no one) appcast, which must both be refused. The app runs with no window and no Dock icon.
set -euo pipefail
cd "$(dirname "$0")/.."

DIR="${1:?usage: scripts/test-update.sh <new-empty-dir>}"
mkdir "$DIR" || { echo "$DIR exists: pass a new folder"; exit 1; }
DIR="$(cd "$DIR" && pwd)"
if ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; then echo "screen locked: not launching the app"; exit 1; fi
OPENSSL="$(command -v /opt/homebrew/opt/openssl@3/bin/openssl || command -v openssl)"
PORT="${PORT:-8765}"

# Throwaway key pair, as files: the private key as generate_keys -x exports it (base64 seed).
"$OPENSSL" genpkey -algorithm ed25519 -out "$DIR/test-key.pem"
PRIV="$("$OPENSSL" pkey -in "$DIR/test-key.pem" -outform DER | tail -c 32 | base64)"
PUB="$("$OPENSSL" pkey -in "$DIR/test-key.pem" -pubout -outform DER | tail -c 32 | base64)"

for v in 1 2; do
  APP="$DIR/v$v/Flockbook.app" BUNDLE_ID=dev.mclee.flockbook.update-test VERSION="0.0.$v" BUILD_NUMBER="$v" SPARKLE_PUBLIC_KEY="$PUB" scripts/bundle.sh >/dev/null
done
mkdir "$DIR/feed" "$DIR/bad" "$DIR/edited"
ditto -c -k --keepParent "$DIR/v2/Flockbook.app" "$DIR/feed/Flockbook-0.0.2.zip"
SPARKLE_ED_PRIVATE_KEY="$PRIV" APP="$DIR/v2/Flockbook.app" DOWNLOAD_PREFIX="http://127.0.0.1:$PORT/" \
  scripts/appcast.sh "$DIR/feed/Flockbook-0.0.2.zip" "$DIR/feed" | sed 's/^/  /'
# Tampered: the same appcast, one byte of the archive changed.
cp "$DIR/feed/appcast.xml" "$DIR/bad/appcast.xml"
cp "$DIR/feed/Flockbook-0.0.2.zip" "$DIR/bad/Flockbook-0.0.2.zip"
printf '\x00' | dd of="$DIR/bad/Flockbook-0.0.2.zip" bs=1 seek=4000 conv=notrunc 2>/dev/null
# Edited: the archive is intact, the appcast text changed after signing.
sed 's#<sparkle:shortVersionString>0.0.2<#<sparkle:shortVersionString>0.0.2 (edited)<#' "$DIR/feed/appcast.xml" > "$DIR/edited/appcast.xml"
cp "$DIR/feed/Flockbook-0.0.2.zip" "$DIR/edited/Flockbook-0.0.2.zip"

version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"; }
fails=0
run() {   # run <name> <feed dir> <expected version afterwards>
  local name="$1" feed="$2" want="$3" app="$DIR/run-$1/Flockbook.app"
  mkdir "$DIR/run-$name"; ditto "$DIR/v1/Flockbook.app" "$app"
  (cd "$feed" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >"$DIR/http-$name.log" 2>&1) & local srv=$!
  sleep 1
  local t0=$SECONDS
  timeout -k 5 60 "$app/Contents/MacOS/HerdrDesk" --test-update "http://127.0.0.1:$PORT/appcast.xml" >"$DIR/app-$name.log" 2>&1 || true
  # Sparkle's installer replaces the bundle after the app quits.
  for _ in $(seq 1 60); do [ "$(version "$app")" = "$want" ] && break; sleep 0.5; done
  kill "$srv" 2>/dev/null || true; wait "$srv" 2>/dev/null || true
  local got; got="$(version "$app")"
  grep '^update-test:' "$DIR/app-$name.log" | sed 's/^/    /'
  if [ "$got" = "$want" ] && codesign --verify --deep --strict "$app"; then
    echo "$name: bundle is $got after $((SECONDS - t0)) s, signature valid ok"
  else
    echo "$name: bundle is $got, want $want FAIL"; fails=$((fails + 1))
  fi
}
run good "$DIR/feed" 0.0.2
run tampered "$DIR/bad" 0.0.1
run edited "$DIR/edited" 0.0.1
grep -q 'FAIL timeout' "$DIR/app-good.log" && { echo "good: the app did not quit for the installer FAIL"; fails=$((fails + 1)); }
for n in tampered edited; do
  grep -q 'FAIL aborted' "$DIR/app-$n.log" && echo "$n: refused with an error ok" || { echo "$n: no error FAIL"; fails=$((fails + 1)); }
done
[ "$fails" = 0 ] && echo "test-update: PASS" || { echo "test-update: FAIL x$fails"; exit 1; }
