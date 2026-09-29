#!/usr/bin/env bash
# Open OakReader's Settings window (Cmd+,) and optionally select a sidebar pane.
#
# The Settings sidebar is a NavigationSplitView rendered as an AXOutline, so panes
# are selected by 1-based ROW INDEX (clicking the row's text is flaky). As of this
# writing the order is:
#   1 General · 2 Library · 3 AI · 4 Agent · 5 Audio · 6 Skills ·
#   7 Extensions · 8 Translation · 9 Web Search
# VERIFY against the live build — panes get reordered.
#
# Usage: open-settings.sh [row_index]
#   OAK_APP_NAME  process name (default: OakReader)
set -euo pipefail

APP="${OAK_APP_NAME:-OakReader}"
ROW="${1:-}"

osascript <<EOF
tell application "$APP" to activate
delay 0.4
tell application "System Events" to keystroke "," using command down
delay 1.0
EOF

if [[ -n "$ROW" ]]; then
  osascript <<EOF
tell application "System Events" to tell process "$APP"
  set theOutline to outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1
  select row $ROW of theOutline
end tell
EOF
  sleep 0.8
fi

echo "opened Settings${ROW:+, selected sidebar row $ROW}"
