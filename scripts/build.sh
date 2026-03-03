#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG=${1:-debug}

swift build -c "$CONFIG" \
  --triple arm64-apple-macosx26.0
