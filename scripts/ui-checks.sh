#!/usr/bin/env bash
# The app's UI checks, one HerdrDesk run each: [ONLY=name,...] scripts/ui-checks.sh [offline|real] [out-dir]
#   offline (default): every check that needs no herdr server and opens no window (preview stores, offscreen windows).
#   real: the two checks with a real window (--test-fullscreen-real, --test-scroll-real). They take the screen and the
#         focus: CI runners only, or with the owner's leave. Needs FLOCKBOOK_VISIBLE_OK=1.
# Not here: the checks that drive a live pane or session (--test-approve, --snapshot-demo, ...): they need a herdr server.
# A check fails when it exits non-zero, runs past its timeout, prints FAIL, or does not print its PASS line.
# Known failures (KNOWN) still run: a failure there is a warning, not a failed run; a pass asks for its removal.
# Each check's output goes to <out-dir>/logs/<name>.log; its pictures to <out-dir>/<name>/ or the app's build/snapshots-*.
set -uo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-offline}"
OUT="${2:-build/ui-checks}"
BIN="${BIN:-.build/debug/HerdrDesk}"
LIMIT="${UI_CHECK_TIMEOUT:-180}"   # seconds per check; a hung check is killed and fails, the others still run

# name | PASS line it must print ("-": exit 0 is the verdict) | arguments
OFFLINE=(
    "snapshot|-|--snapshot $OUT/snapshot"
    "snapshot-reading|-|--snapshot-reading $OUT/snapshot-reading"
    "snapshot-settings|snapshot-settings: PASS|--snapshot-settings $OUT/snapshot-settings"
    "snapshot-remote|snapshot-remote: PASS|--snapshot-remote $OUT/snapshot-remote"
    "snapshot-statusline|snapshot-statusline: PASS|--snapshot-statusline $OUT/snapshot-statusline"
    "hittest|hittest: overflow check PASS|--hittest"
    "chrome|chrome-test: PASS|--test-chrome"
    "table|table-test: PASS|--test-table"
    "bottom|bottom-test: PASS|--test-bottom"
    "closetab|closetab-test: PASS|--test-closetab"
    "menus|menus-test: PASS|--test-menus"
    "tabdrag|tabdrag-test: PASS|--test-tabdrag"
    "panemenu|panemenu-test: PASS|--test-panemenu"
    "composer|composer-test: PASS|--test-composer"
    "sidebar|sidebar-test: PASS|--test-sidebar"
    "sidebar-layout|sidebar-layout: PASS|--test-sidebar-layout"
    "root-width|root-width: PASS|--test-root-width"
    "settings-migration|settings-migration: PASS|--test-settings-migration"
    "island-height|island-height: PASS|--test-island-height"
    "tab-overflow|tab-overflow: PASS|--test-tab-overflow"
    "tabkeys|tabkeys-test: PASS|--test-tabkeys"
    "settings-page|settings-page-test: PASS|--test-settings-page"
    "sendfail|sendfail-test: PASS|--test-sendfail"
    "loadstate|loadstate-test: PASS|--test-loadstate"
    "termfail|termfail-test: PASS|--test-termfail"
    "termtheme|termtheme-test: PASS|--test-termtheme"
    "glyph|glyph-test: PASS|--test-glyph"
    "panebars|panebars-test: PASS|--test-panebars"
    "surfaces|surfaces-test: PASS|--test-surfaces"
    "search|search-test: PASS|--test-search"
    "textsize|textsize-test: PASS|--test-textsize"
    "scrolltop|scrolltop-test: PASS|--test-scrolltop"
    "shortcuts|shortcuts-test: PASS|--test-shortcuts"
    "question|question-test: PASS|--test-question"
    "permission|permission-test: PASS|--test-permission"
    "screencolumn|screencolumn-test: PASS|--test-screencolumn"
    "conversation-churn|churn-test: PASS|--test-conversation-churn"
    "busy-tab|busy-tab: PASS|--test-busy-tab"
    "legacy-look|legacy-look-test: PASS|--test-legacy-look"
    "pictures|pictures-test: PASS|--test-pictures"
)
REAL=(
    "fullscreen-real|fs-real|--preview --test-fullscreen-real"
    "scroll-real|scroll-real|--preview --test-scroll-real"
)
# Fail on the CI runner's newer macOS (26.6), pass on 26.1: to be looked into, then removed from here.
KNOWN=" island-height settings-page screencolumn glyph "
case "$MODE" in
    offline) CHECKS=("${OFFLINE[@]}") ;;
    real)
        [ "${FLOCKBOOK_VISIBLE_OK:-}" = 1 ] || { echo "ui-checks: real opens a window: set FLOCKBOOK_VISIBLE_OK=1" >&2; exit 2; }
        CHECKS=("${REAL[@]}") ;;
    *) echo "usage: scripts/ui-checks.sh [offline|real] [out-dir]" >&2; exit 2 ;;
esac

# ONLY="question busy-tab" (spaces or commas): run just these. A name of the other mode is skipped; an unknown name exits 2.
if [ -n "${ONLY:-}" ]; then
    known_names=" "; for entry in "${OFFLINE[@]}" "${REAL[@]}"; do known_names+="${entry%%|*} "; done
    for want in ${ONLY//,/ }; do
        [[ "$known_names" == *" $want "* ]] || { echo "ui-checks: no check named '$want' (ONLY)" >&2; exit 2; }
    done
    picked=()
    for entry in "${CHECKS[@]}"; do
        [[ " ${ONLY//,/ } " == *" ${entry%%|*} "* ]] && picked+=("$entry")
    done
    [ ${#picked[@]} -gt 0 ] || { echo "ui-checks $MODE: nothing to run (ONLY=$ONLY)"; exit 0; }
    CHECKS=("${picked[@]}")
fi

if ioreg -n Root -d1 | grep -q '"CGSSessionScreenIsLocked"=Yes'; then
    echo "ui-checks: screen is locked; not starting" >&2; exit 3
fi
[ -x "$BIN" ] || { echo "ui-checks: $BIN not found: run swift build first" >&2; exit 2; }
mkdir -p "$OUT/logs"
# A herdr pane's variables would point the app at the owner's session.
unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_ENV


# Runs "$@" with a time limit (macOS has no timeout(1)): TERM at the limit, KILL 5 s later. Exit 124 on a timeout.
run_limited() {
    local limit=$1; shift
    "$@" & local pid=$!
    ( sleep "$limit"; kill -TERM "$pid" 2>/dev/null && { sleep 5; kill -KILL "$pid" 2>/dev/null; }; ) & local guard=$!
    wait "$pid"; local code=$?
    if kill -0 "$guard" 2>/dev/null; then kill "$guard" 2>/dev/null; wait "$guard" 2>/dev/null; else code=124; fi
    return "$code"
}

failed=(); known_failed=()
summary="$OUT/summary.txt"; : > "$summary"
for entry in "${CHECKS[@]}"; do
    IFS='|' read -r name pass argline <<< "$entry"
    read -r -a args <<< "$argline"
    log="$OUT/logs/$name.log"
    [ "$MODE" = real ] && export FS_REAL_DIR="$OUT/$name"
    start=$(date +%s)
    run_limited "$LIMIT" "$BIN" "${args[@]}" > "$log" 2>&1; code=$?
    secs=$(( $(date +%s) - start ))
    verdict=ok
    if [ "$code" = 124 ]; then verdict="timeout after ${LIMIT}s"
    elif [ "$code" != 0 ]; then verdict="exit $code"
    elif grep -q 'FAIL' "$log"; then verdict="FAIL line"
    elif [ "$pass" != - ] && ! grep -qF "$pass" "$log"; then verdict="no '$pass' line"
    fi
    line=$(printf '%-20s %4ss  %s' "$name" "$secs" "$verdict")
    echo "$line" | tee -a "$summary"
    grep 'WARN (CI runner' "$log" | sed "s/^/::warning title=ui-checks::$name: /"   # timing misses a CI runner does not count
    known=no; [[ "$KNOWN" == *" $name "* ]] && known=yes
    if [ "$verdict" != ok ]; then
        if [ "$known" = yes ]; then
            known_failed+=("$name"); echo "::warning title=ui-checks::$name fails ($verdict): known failure, not counted"
        else
            failed+=("$name")
        fi
        grep 'FAIL' "$log" | sed "s/^/$name failed: /"   # every FAIL line, also those above the tail below
        echo "::group::$name log"; tail -40 "$log"; echo "::endgroup::"
    elif [ "$known" = yes ]; then
        echo "::notice title=ui-checks::$name passes now: remove it from KNOWN in scripts/ui-checks.sh"
    fi
done
echo "ui-checks $MODE: $(( ${#CHECKS[@]} - ${#failed[@]} - ${#known_failed[@]} ))/${#CHECKS[@]} passed${failed:+; failed: ${failed[*]}}${known_failed:+; known failures: ${known_failed[*]}}" | tee -a "$summary"
[ ${#failed[@]} = 0 ]
