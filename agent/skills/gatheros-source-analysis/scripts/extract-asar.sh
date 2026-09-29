#!/usr/bin/env bash
# Recover GatherOS's source (the big win) and print a one-shot fingerprint.
#
# Unlike Dia (native Swift, source maps) and Fabric (renderer served from a
# CDN), GatherOS is a SELF-CONTAINED Electron app: the entire main process
# ships UNMINIFIED inside app.asar, and the React renderer is a bundled Vite
# build in dist/renderer/. So recovery is just "extract the asar" — no curl,
# no source maps, no cache spelunking.
#
# Usage:  ./extract-asar.sh [/tmp/gatheros-src]
set -euo pipefail

APP="/Applications/GatherOS.app"
ASAR="$APP/Contents/Resources/app.asar"
OUT="${1:-/tmp/gatheros-src}"

[ -d "$APP" ] || { echo "GatherOS not installed at $APP"; exit 1; }

echo "== version =="
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier"        "$APP/Contents/Info.plist"

echo "== extracting asar -> $OUT =="
rm -rf "$OUT"
npx --yes @electron/asar extract "$ASAR" "$OUT" >/dev/null 2>&1
echo "extracted ($(find "$OUT/src" -name '*.js' | wc -l | tr -d ' ') main-process .js files)"

echo "== main-process modules (unminified, read these directly) =="
wc -l "$OUT"/src/main/*.js | sort -n | tail -22

echo "== preload bridge: window.moodmark.* namespaces =="
grep -oE "^[[:space:]]*[a-zA-Z]+:[[:space:]]*\{" "$OUT/src/main/preload.js" | tr -d ' {:' | sort -u | tr '\n' ' '; echo

echo "== renderer framework fingerprint =="
( cd "$OUT/dist/renderer/assets" && for kw in React useState createElement masonry; do
    echo "  $kw : $(grep -lE "$kw" main-*.js 2>/dev/null | wc -l | tr -d ' ')"; done )

echo "== DB schema (tables) =="
grep -oE "CREATE TABLE IF NOT EXISTS [a-z_]+" "$OUT/src/main/db.js" | awk '{print "  "$NF}'

echo
echo "Done. Main process: $OUT/src/main/  |  Renderer: $OUT/dist/renderer/"
echo "Live user data lives OUTSIDE the bundle under:"
echo "  ~/Library/Application Support/GatherOS/libraries/<id>/moodmark.db  (+ images/ thumbs/)"
