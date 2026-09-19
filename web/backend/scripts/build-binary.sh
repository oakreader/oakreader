#!/usr/bin/env bash
# Compile the sidecar into a self-contained executable with `bun build --compile`.
#
# This replaces "bundle a Node runtime + a .cjs": the Bun runtime is embedded in
# the binary, so the app never probes for `node` and there is no minimum Node
# version. Same approach Dia ships (its agent-server/handler/claude are all
# `bun build --compile` outputs).
#
#   OAK_UNIVERSAL=1   build x86_64 + arm64 and lipo them (release; mirrors the
#                     app, whose Release build is a fat binary)
#   default           arm64 only (local dev; matches ONLY_ACTIVE_ARCH Debug)
#   OAK_TARGET=win    cross-compile a Windows .exe -- works from macOS
#
# The output is NOT committed: at 63 MB (arm64) / 132 MB (universal) it does not
# belong in git. The Xcode build phase calls this script.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BUN="${BUN:-$(command -v bun || true)}"
if [[ -z "$BUN" ]]; then
    echo "error: bun not found. Install from https://bun.sh (the sidecar is compiled with it)." >&2
    exit 1
fi

mkdir -p dist
entry="src/main.ts"

case "${OAK_TARGET:-mac}" in
  win)
    echo "==> Building Windows x64 executable"
    "$BUN" build "$entry" --compile --target=bun-windows-x64 --outfile=dist/oak-backend.exe
    ;;
  *)
    if [[ "${OAK_UNIVERSAL:-0}" == "1" ]]; then
        echo "==> Building universal (x86_64 + arm64)"
        tmp="$(mktemp -d)"
        "$BUN" build "$entry" --compile --target=bun-darwin-arm64 --outfile="$tmp/arm64"
        "$BUN" build "$entry" --compile --target=bun-darwin-x64   --outfile="$tmp/x64"
        lipo -create "$tmp/arm64" "$tmp/x64" -output dist/oak-backend
        rm -rf "$tmp"
    else
        echo "==> Building arm64"
        "$BUN" build "$entry" --compile --target=bun-darwin-arm64 --outfile=dist/oak-backend
    fi
    chmod +x dist/oak-backend
    lipo -info dist/oak-backend 2>/dev/null || true
    ;;
esac
echo "==> $(cd dist && pwd)/oak-backend$( [[ "${OAK_TARGET:-mac}" == win ]] && echo .exe )"
