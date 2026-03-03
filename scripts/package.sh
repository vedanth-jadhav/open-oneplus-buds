#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG=${1:-release}
APP_PATH="$ROOT/dist/Buds.app"
ZIP_PATH="$ROOT/dist/Buds.zip"
DMG_PATH="$ROOT/dist/Buds.dmg"

./scripts/bundle.sh "$CONFIG"

# Sign so macOS permissions persist better across rebuilds. Prefer a stable identity if available.
if [[ -x "$ROOT/scripts/sign_app.sh" ]]; then
  "$ROOT/scripts/sign_app.sh" "$APP_PATH" || true
fi

# If macOS attached quarantine (for example when copying from another machine),
# remove it so Finder doesn't block launch.
/usr/bin/xattr -dr com.apple.quarantine "$APP_PATH" >/dev/null 2>&1 || true

rm -f "$ZIP_PATH" "$DMG_PATH"

# Create a Finder-friendly zip (keeps resource forks).
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

# Optional DMG for drag-and-drop installs.
if command -v hdiutil >/dev/null 2>&1; then
  /usr/bin/hdiutil create -volname "Buds" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH" >/dev/null
fi

echo "Packaged:"
echo "  App: $APP_PATH"
echo "  Zip: $ZIP_PATH"
if [[ -f "$DMG_PATH" ]]; then
  echo "  Dmg: $DMG_PATH"
fi
