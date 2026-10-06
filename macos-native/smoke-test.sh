#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
"$ROOT/build.sh"
mkdir -p "$ROOT/.checks"
RELOCATED="$(mktemp -d "$ROOT/.checks/relocated.XXXXXX")"
trap 'rm -rf "$RELOCATED/SidePulse Native.app"; rmdir "$RELOCATED"' EXIT
/usr/bin/ditto "$ROOT/dist/SidePulse Native.app" "$RELOCATED/SidePulse Native.app"
SIDEPULSE_NATIVE_APP="$RELOCATED/SidePulse Native.app" "$ROOT/test.sh" "$@"
