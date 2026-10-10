#!/usr/bin/env bash
# Open the built app. Pass `--session <name>` to point it at a named herdr session.
# Without arguments it reads the default session (read-only unless you type in the composer).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Flockbook.app"
[ -d "$APP" ] || scripts/bundle.sh
if [ "$#" -gt 0 ]; then
  open -n "$APP" --args "$@"
else
  open -n "$APP"
fi
