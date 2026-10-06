#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./macos-native/build-release.sh

Build and test the native app in Release mode, then create a versioned ZIP
and SHA-256 checksum in macos-native/dist/. Requires macOS and full Xcode.

The build targets the current Mac's architecture. Version and build numbers
come from macos-native/Resources/Info.plist.

Optional environment variables:
  DEVELOPER_DIR   Override the Xcode developer directory.
  SIGN_IDENTITY  Signing identity; defaults to ad-hoc signing for local use.

This script does not install the app, change hooks, or notarize the archive.
EOF
}

if [ "$#" -gt 0 ]; then
    if [ "$#" -eq 1 ] && { [ "$1" = "--help" ] || [ "$1" = "-h" ]; }; then
        usage
        exit 0
    fi
    usage >&2
    exit 2
fi

if [ "$(uname -s)" != Darwin ]; then
    printf 'Error: native releases must be built on macOS.\n' >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/SidePulse Native.app"

CONFIGURATION=release "$ROOT/smoke-test.sh" -c release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
for value in "$VERSION" "$BUILD"; do
    if [[ ! "$value" =~ ^[[:alnum:]][[:alnum:]._-]*$ ]]; then
        printf 'Error: invalid release version or build number: %s\n' "$value" >&2
        exit 1
    fi
done
ARCHITECTURES="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/SidePulseNative" | tr ' ' '-')"
ARCHIVE="SidePulse-Native-$VERSION-$BUILD-$ARCHITECTURES.zip"
STAGING="$(mktemp -d "$ROOT/dist/.release.XXXXXX")"
trap 'rm -f "$STAGING/$ARCHIVE" "$STAGING/$ARCHIVE.sha256"; rmdir "$STAGING"' EXIT

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/$ARCHIVE"
(
    cd "$STAGING"
    /usr/bin/shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
)
mv -f "$STAGING/$ARCHIVE" "$STAGING/$ARCHIVE.sha256" "$ROOT/dist/"

printf '\nRelease app: %s\nArchive: %s\nChecksum: %s\n' \
    "$APP" "$ROOT/dist/$ARCHIVE" "$ROOT/dist/$ARCHIVE.sha256"
printf 'Not notarized; public distribution requires Developer ID signing and notarization.\n'
