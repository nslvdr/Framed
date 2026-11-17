#!/usr/bin/env bash
# Installs (or updates) Framed from the latest GitHub release:
#   curl -fsSL https://raw.githubusercontent.com/nslvdr/Framed/main/scripts/install.sh | bash
# Files fetched with curl aren't quarantined, so Gatekeeper doesn't block the
# un-notarized app the way it would after a browser download.
set -euo pipefail

URL="https://github.com/nslvdr/Framed/releases/latest/download/Framed.zip"
DEST="/Applications"
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Framed…"
curl -fsSL "$URL" -o "$TMP/Framed.zip"
ditto -x -k "$TMP/Framed.zip" "$TMP"

pkill -x Framed 2>/dev/null || true
while pgrep -x Framed >/dev/null; do sleep 0.1; done
rm -rf "$DEST/Framed.app"
mv "$TMP/Framed.app" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/Framed.app" 2>/dev/null || true

echo "Installed to $DEST/Framed.app"
open "$DEST/Framed.app"
