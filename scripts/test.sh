#!/usr/bin/env bash
# Runs the test suite. With only the Command Line Tools installed, SwiftPM doesn't find
# the Swift Testing macro plugin on its own, so point it there explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
if [[ -d "$PLUGINS" ]]; then
    swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
    swift test "$@"
fi
