#!/bin/sh
# Rebuilds the Flockbook demo herdr session from scratch (fictional projects, no model runs).
# usage: scripts/demo-seed.sh [--session NAME] [--root DIR] [--files-only]
#   --session  herdr session to seed (default flockbook-demo; the name must contain "demo")
#   --root     parent folder of the fictional projects (default ~/Demo)
# Every pane runs a stub that only prints a scripted screen; see scripts/demo/gen.py for what is written where.
# Safe to rerun: it builds the new layout, then closes the workspaces that were there before.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root="$HOME/Demo"
prev=""
for a in "$@"; do
  [ "$prev" = "--root" ] && root="$a"
  prev="$a"
done
bin="$root/.flockbook-demo/bin"
mkdir -p "$bin"
cc -O2 -o "$bin/demo-agent" "$here/demo/stub.c"
for k in claude codex pi; do ln -sf demo-agent "$bin/$k"; done
PYTHONDONTWRITEBYTECODE=1 exec python3 "$here/demo/gen.py" --bin "$bin" "$@"
