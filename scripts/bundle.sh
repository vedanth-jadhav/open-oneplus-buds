#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG=${1:-release}
APP_NAME="Buds"
BUNDLE_ID="com.vedanth.open-oneplus-buds"

./scripts/build.sh "$CONFIG"

BIN_PATH="$ROOT/.build/$CONFIG/BudsApp"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "Binary not found at $BIN_PATH" >&2
  exit 1
fi

OUT="$ROOT/dist/$APP_NAME.app"
CONTENTS="$OUT/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

mkdir -p "$MACOS" "$RES"

cp "$BIN_PATH" "$MACOS/$APP_NAME"

# App icon (for Finder / Login Items). Optional but preferred.
if [[ -f "$ROOT/Assets/Buds.icns" ]]; then
  cp "$ROOT/Assets/Buds.icns" "$RES/Buds.icns"
fi

# Copy SwiftPM resource bundles (created by SwiftPM for targets with resources).
# This is required for Bundle.module lookups.
if [[ -d "$ROOT/.build/$CONFIG" ]]; then
  # .build/debug is often a symlink; follow it so we can find the resource bundle.
  find -L "$ROOT/.build/$CONFIG" -name "*.bundle" -print0 | while IFS= read -r -d '' b; do
    cp -R "$b" "$RES/"
  done
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>Buds</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Connect to earbuds to query battery and control noise cancelling.</string>
  <key>NSBluetoothPeripheralUsageDescription</key>
  <string>Connect to earbuds to query battery and control noise cancelling.</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$CONTENTS/Info.plist" >/dev/null

echo "Built: $OUT"

# Optional signing:
# - If you have a real signing identity, permissions (like Bluetooth) persist better across rebuilds.
# - Set CODESIGN_IDENTITY to force a specific identity.
if [[ -x "$ROOT/scripts/sign_app.sh" ]]; then
  "$ROOT/scripts/sign_app.sh" "$OUT" || true
fi
