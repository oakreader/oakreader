#!/usr/bin/env bash
# Click at a WINDOW-RELATIVE point — the same (dx,dy) you measured on a
# capture-window.sh screenshot. Re-reads the live window origin and adds your
# offset, so the click lands correctly even if the window moved or reopened on a
# different display. (Never hardcode global click coords across calls.)
#
# `click at` conveniently echoes the AX element it hit — use it to confirm you
# clicked the intended control.
#
# Usage: click-in-window.sh <dx> <dy>
#   OAK_APP_NAME  process name (default: OakReader)
set -euo pipefail

APP="${OAK_APP_NAME:-OakReader}"
DX="$1"
DY="$2"

POS=$(osascript -e "tell application \"System Events\" to tell process \"$APP\" to get position of window 1")
POS=${POS//,/ }
read -r X Y <<< "$POS"

GX=$(( X + DX ))
GY=$(( Y + DY ))

HIT=$(osascript -e "tell application \"System Events\" to click at {$GX, $GY}" 2>&1 || true)
echo "clicked window-relative ($DX,$DY) -> screen ($GX,$GY)"
[[ -n "$HIT" ]] && echo "hit: $HIT"
