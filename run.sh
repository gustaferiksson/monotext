#!/bin/bash
# Build monotext and launch it as a minimal .app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "› building"
swift build --package-path "$ROOT" -c debug

"$ROOT/bundle.sh" debug

pkill -x monotext 2>/dev/null || true
open -n "$ROOT/.build/MonoText.app"
