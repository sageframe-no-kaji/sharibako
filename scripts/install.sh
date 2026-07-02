#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${SHARIBAKO_INSTALL_DIR:-/usr/local/bin}"

cd "$REPO_ROOT"
echo "Building sharibako (release)..."
swift build -c release --product sharibako
BINARY_PATH="$REPO_ROOT/.build/release/sharibako"

if [[ ! -f "$BINARY_PATH" ]]; then
    echo "Error: build succeeded but binary not found at $BINARY_PATH" >&2
    exit 1
fi

mkdir -p "$DEST"
install -m 0755 "$BINARY_PATH" "$DEST/sharibako"
echo "Installed sharibako to $DEST/sharibako"
"$DEST/sharibako" --version
