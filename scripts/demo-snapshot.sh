#!/bin/sh
# README / website stills from the flockbook-demo session (run scripts/demo-seed.sh first).
# usage: scripts/demo-snapshot.sh [out-dir]   -> <out>/<shot>-light.png and <shot>-dark.png
# Offscreen, no Dock icon, read-only. Refuses to start while the screen is locked.
set -eu
out=${1:-docs/media}
cd "$(dirname "$0")/.."
for look in light dark; do
    if ioreg -n Root -d1 | grep -q '"CGSSessionScreenIsLocked"=Yes'; then
        echo "demo-snapshot: screen is locked; not starting" >&2; exit 3
    fi
    flag=; [ "$look" = dark ] && flag=--dark
    env -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_ENV \
        timeout -k 5 60 .build/debug/HerdrDesk --session flockbook-demo --snapshot-demo "$out" $flag
done
