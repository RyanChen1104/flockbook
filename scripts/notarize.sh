#!/usr/bin/env bash
# Notarize and staple build/Flockbook.app (default) or a .dmg given as $1. Sign it first:
# the app with SIGN_ID set (see scripts/bundle.sh), the dmg via scripts/package.sh.
# Credentials, either:
#   - env APPLE_ID, APPLE_PASSWORD (app-specific password), APPLE_TEAM_ID (used by CI), or
#   - a keychain profile, one-time setup:
#       xcrun notarytool store-credentials flockbook \
#         --apple-id <apple id> --team-id <TEAMID> --password <app-specific password>
# Uploads the file to Apple. Run it only for a release.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-build/Flockbook.app}"
PROFILE="${NOTARY_PROFILE:-flockbook}"

[ -e "$TARGET" ] || { echo "missing: $TARGET (run scripts/bundle.sh)"; exit 1; }
codesign -dv "$TARGET" 2>&1 | grep -q 'Authority=Developer ID Application' \
  || { echo "not Developer ID signed: $TARGET"; exit 1; }

if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  CREDS=(--apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID")
else
  CREDS=(--keychain-profile "$PROFILE")
fi

case "$TARGET" in
  *.app)
    SUBMIT="$(mktemp -d)/notarize.zip"
    ditto -c -k --keepParent "$TARGET" "$SUBMIT" ;;
  *) SUBMIT="$TARGET" ;;
esac
xcrun notarytool submit "$SUBMIT" "${CREDS[@]}" --wait
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
case "$TARGET" in
  *.app) spctl --assess --type execute -vv "$TARGET"; rm -f "$SUBMIT" ;;
esac
echo "notarized: $TARGET"
