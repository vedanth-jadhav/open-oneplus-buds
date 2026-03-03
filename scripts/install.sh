#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG=${1:-release}

./scripts/package.sh "$CONFIG"

SRC="$ROOT/dist/Buds.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/Buds.app"

mkdir -p "$DEST_DIR"
rm -rf "$DEST"

# Preserve extended attributes/resources when copying bundles.
/usr/bin/ditto "$SRC" "$DEST"

/usr/bin/xattr -dr com.apple.quarantine "$DEST" >/dev/null 2>&1 || true

echo "Installed: $DEST"
echo "Tip: macOS Login Items -> add Buds.app if you want it to start automatically."

