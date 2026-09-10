#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
xcrun swift test --package-path "$ROOT" --scratch-path "$ROOT/.build" \
    --cache-path "$ROOT/.build/cache" "$@"
