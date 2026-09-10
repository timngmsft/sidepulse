#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
CONFIGURATION="${CONFIGURATION:-release}"
IDENTITY="${SIGN_IDENTITY:--}"

xcrun swift build --package-path "$ROOT" --scratch-path "$ROOT/.build" \
    --cache-path "$ROOT/.build/cache" -c "$CONFIGURATION"
BIN="$(xcrun swift build --package-path "$ROOT" --scratch-path "$ROOT/.build" \
    --cache-path "$ROOT/.build/cache" -c "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/dist/SidePulse Native.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/SidePulseNative" "$APP/Contents/MacOS/SidePulseNative"
cp "$BIN/SidePulseHook" "$APP/Contents/Helpers/SidePulseHook"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
xcrun swift "$ROOT/Tools/GenerateIcon.swift" "$ROOT/.build/AppIcon.iconset"
/usr/bin/iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ROOT/.build/AppIcon.iconset"
chmod 755 "$APP/Contents/MacOS/SidePulseNative" "$APP/Contents/Helpers/SidePulseHook"
/usr/bin/codesign --force --sign "$IDENTITY" --options runtime "$APP/Contents/Helpers/SidePulseHook"
/usr/bin/codesign --force --sign "$IDENTITY" --options runtime "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
printf '\nBuilt: %s\n' "$APP"
