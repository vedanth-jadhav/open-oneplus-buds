#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT_DIR="$ROOT/Assets"
ICONSET="$OUT_DIR/Buds.iconset"
ICNS="$OUT_DIR/Buds.icns"

mkdir -p "$OUT_DIR"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

swift "$ROOT/scripts/render_app_icon.swift" "$ICONSET"

if ! command -v iconutil >/dev/null 2>&1; then
  echo "iconutil not found (required to build .icns)" >&2
  exit 1
fi

iconutil -c icns "$ICONSET" -o "$ICNS"

echo "Wrote:"
echo "  $ICONSET"
echo "  $ICNS"

