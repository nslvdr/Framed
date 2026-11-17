#!/usr/bin/env bash
# Builds Framed.app into ./build. Usage: scripts/bundle.sh [--run]
# Signs with the first "Apple Development" identity found (so the Screen Recording
# permission survives rebuilds), or ad-hoc otherwise. Override with SIGN_IDENTITY.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Framed"

APP="build/Framed.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Framed"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"' || true)}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--run" ]]; then
    pkill -x Framed || true
    open "$APP"
fi
