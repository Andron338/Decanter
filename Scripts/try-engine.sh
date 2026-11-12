#!/bin/bash
# Tries a Windows program on an arbitrary Wine build in a throwaway bottle and reports how far it got.
# Usage: Scripts/try-engine.sh <wine-root> <path/to/game.exe> [seconds]
#   <wine-root> is the folder that contains bin/wine (or bin/wine64) and bin/wineserver.
set -uo pipefail

ROOT="${1:?wine root (folder containing bin/)}"
EXE="${2:?path to .exe}"
SECONDS_TO_WATCH="${3:-50}"

WINE="$ROOT/bin/wine"
[ -x "$WINE" ] || WINE="$ROOT/bin/wine64"
[ -x "$WINE" ] || { echo "No wine binary in $ROOT/bin"; exit 2; }

# Some engine archives (e.g. Sikarugir's) ship without their support libraries (libinotify, freetype,
# gnutls, MoltenVK…) because a wrapper app normally supplies them. Borrow the copies in Decanter's
# own runtimes, which come from the same builder.
RUNTIMES="$HOME/Library/Application Support/Decanter/Runtimes"
FALLBACK=""
for lib in "$ROOT/lib" "$RUNTIMES"/wine-*/*.app/Contents/Resources/wine/lib "$RUNTIMES"/gptk-*/*.app/Contents/Resources/wine/lib; do
    [ -d "$lib" ] && FALLBACK="$FALLBACK$lib:"
done
export DYLD_FALLBACK_LIBRARY_PATH="${FALLBACK}/usr/local/lib:/usr/lib"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/decanter-try.XXXXXX")"
LOG="$WORK/run.log"
export WINEPREFIX="$WORK/prefix"
NAME="$(basename "$EXE")"

echo "Engine:  $(WINEDEBUG=-all "$WINE" --version 2>/dev/null)"
echo "Bottle:  $WINEPREFIX"
echo "Creating bottle…"
WINEDEBUG=-all "$WINE" wineboot -u >/dev/null 2>&1
"$ROOT/bin/wineserver" -w

cd "$(dirname "$EXE")" || exit 2
echo "Launching $NAME for up to ${SECONDS_TO_WATCH}s…"
WINEDEBUG=fixme-all,trace+d3d9,trace+d3d11 WINEMSYNC=1 "$WINE" "$NAME" >"$LOG" 2>&1 &

elapsed=0
alive=1
while [ "$elapsed" -lt "$SECONDS_TO_WATCH" ]; do
    sleep 5
    elapsed=$((elapsed + 5))
    alive=$(ps ax -o command | grep -F "$NAME" | grep -v -e grep -e try-engine | wc -l | tr -d ' ')
    echo "  ${elapsed}s: running=$([ "$alive" -gt 0 ] && echo yes || echo no)  direct3d-calls=$(grep -c 'trace:d3d' "$LOG")"
    [ "$alive" -eq 0 ] && break
done

echo
echo "Result:  $([ "$alive" -gt 0 ] && echo "still running after ${elapsed}s" || echo "exited after about ${elapsed}s")"
echo "Direct3D calls logged: $(grep -c 'trace:d3d' "$LOG")"
echo "Errors:"
grep -E "page fault|Assertion|err:" "$LOG" | grep -v clipboard | cut -c1-160 | sort | uniq -c | sort -rn | head -8

"$ROOT/bin/wineserver" -k
echo
echo "Full log: $LOG"
echo "Delete the test bottle with: rm -rf \"$WORK\""
