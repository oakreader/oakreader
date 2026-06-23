#!/bin/bash
# Creates xcconfig/DeveloperSettings.xcconfig (gitignored) so you can build
# OakReader with your own Apple team — or ad-hoc — without editing any tracked
# file. See README "Build".
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="xcconfig/DeveloperSettings.xcconfig"

if [ -f "$DEST" ]; then
  echo "$DEST already exists — leaving it untouched."
  echo "Delete it first if you want to reconfigure."
  exit 0
fi

echo "Set up local code signing for OakReader."
echo "If you have an Apple Developer account (a free Apple ID works), enter your"
echo "Team ID — developer.apple.com → Account → Membership. Leave blank to build"
echo "ad-hoc (no Apple account required; local dev only)."
read -r -p "Apple Developer Team ID (blank = ad-hoc): " TEAM

if [ -z "${TEAM}" ]; then
  cat > "$DEST" <<'EOF'
// Ad-hoc local signing — no Apple account required.
DEVELOPMENT_TEAM =
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = -
EOF
else
  cat > "$DEST" <<EOF
// Local signing override for team ${TEAM}
DEVELOPMENT_TEAM = ${TEAM}
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
EOF
fi

echo
echo "Wrote $DEST:"
echo "────────────────────────────────────────"
cat "$DEST"
echo "────────────────────────────────────────"
echo
echo "Done. Open the Debug scheme in Xcode and build (Cmd+R)."
