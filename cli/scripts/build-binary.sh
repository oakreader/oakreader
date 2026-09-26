#!/usr/bin/env bash
# Compile `oak` into a self-contained executable with `bun build --compile`.
#
# Same shape as the sidecar's build: the Bun runtime is embedded, so the binary
# has no interpreter to find and nothing to install alongside it. The CLI was
# Swift until it shared a catalog with the core; compiling it this way is also
# what lets it run where Swift cannot.
#
#   OAK_UNIVERSAL=1   build x86_64 + arm64 and lipo them (release)
#   default           arm64 only (local dev)
#   OAK_TARGET=win    cross-compile a Windows .exe -- works from macOS
#
# The output is not committed; the Xcode build phase calls this script.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BUN="${BUN:-$(command -v bun || true)}"
if [[ -z "$BUN" ]]; then
    echo "error: bun not found. Install from https://bun.sh (the CLI is compiled with it)." >&2
    exit 1
fi

mkdir -p dist
entry="src/main.ts"

case "${OAK_TARGET:-mac}" in
  win)
    echo "==> Building Windows x64 executable"
    "$BUN" build "$entry" --compile --target=bun-windows-x64 --outfile=dist/oak.exe
    ;;
  *)
    if [[ "${OAK_UNIVERSAL:-0}" == "1" ]]; then
        echo "==> Building universal (x86_64 + arm64)"
        tmp="$(mktemp -d)"
        "$BUN" build "$entry" --compile --target=bun-darwin-arm64 --outfile="$tmp/arm64"
        "$BUN" build "$entry" --compile --target=bun-darwin-x64   --outfile="$tmp/x64"
        lipo -create "$tmp/arm64" "$tmp/x64" -output dist/oak
        rm -rf "$tmp"
    else
        echo "==> Building arm64"
        "$BUN" build "$entry" --compile --target=bun-darwin-arm64 --outfile=dist/oak
    fi
    chmod +x dist/oak
    lipo -info dist/oak 2>/dev/null || true
    ;;
esac
echo "==> $(cd dist && pwd)/oak$( [[ "${OAK_TARGET:-mac}" == win ]] && echo .exe )"
