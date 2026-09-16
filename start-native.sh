#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/macos-native/dist/SidePulse Native.app"

if [ ! -x "$APP/Contents/MacOS/SidePulseNative" ]; then
    printf 'Native app not found. Build it first with:\n  "%s/macos-native/build.sh"\n' "$ROOT" >&2
    exit 1
fi

exec /usr/bin/open "$APP" --args "$@"
