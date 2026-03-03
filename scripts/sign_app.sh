#!/bin/zsh
set -euo pipefail

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "Usage: sign_app.sh <path-to-app-bundle>" >&2
  exit 2
fi

if ! command -v codesign >/dev/null 2>&1; then
  echo "codesign not available; skipping signing" >&2
  exit 0
fi

pick_identity() {
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    print -r -- "$CODESIGN_IDENTITY"
    return
  fi

  if ! command -v security >/dev/null 2>&1; then
    print -r -- "-"
    return
  fi

  # Prefer stable identities so macOS permissions (TCC) persist across rebuilds.
  # If no identity exists, fall back to ad-hoc signing ("-").
  local out
  out="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"

  # "Apple Development: Name (TEAMID)" is ideal for local builds.
  local dev
  dev="$(print -r -- "$out" | sed -nE 's/^[[:space:]]*[0-9]+\) [0-9A-F]+ \"(Apple Development: .*)\"$/\1/p' | head -n 1 || true)"
  if [[ -n "$dev" ]]; then
    print -r -- "$dev"
    return
  fi

  # Fallback: Developer ID Application (also stable if present).
  local did
  did="$(print -r -- "$out" | sed -nE 's/^[[:space:]]*[0-9]+\) [0-9A-F]+ \"(Developer ID Application: .*)\"$/\1/p' | head -n 1 || true)"
  if [[ -n "$did" ]]; then
    print -r -- "$did"
    return
  fi

  print -r -- "-"
}

IDENTITY="$(pick_identity)"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
fi

echo "Signing: $APP_PATH"
echo "Identity: $IDENTITY"
if [[ "$IDENTITY" == "-" && -z "${CODESIGN_IDENTITY:-}" ]]; then
  echo "Note: no signing identity found; using ad-hoc signing." >&2
  echo "      For 'Bluetooth permission only once', create/use a stable signing identity and set CODESIGN_IDENTITY." >&2
fi

# --deep is needed because SwiftPM resources are embedded in nested *.bundle(s).
/usr/bin/codesign --force --deep --sign "$IDENTITY" "$APP_PATH" >/dev/null 2>&1 || true

echo "Signed (best-effort)"
