#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

./scripts/bundle.sh debug

# If you want terminal debug output, run the app binary directly so env vars apply.
if [[ "${BUDS_DEBUG:-}" == "1" ]]; then
  "dist/Buds.app/Contents/MacOS/Buds"
else
  open "dist/Buds.app"
fi
