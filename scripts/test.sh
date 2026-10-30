#!/bin/bash
# Runs the FolderSync test suite (Swift Testing). Usage: scripts/test.sh [swift test args…]
#
# With only the Command Line Tools installed, SwiftPM's explicit-module build sometimes omits the
# Swift Testing macro plugin from the module-emitting job ("plugin for module 'TestingMacros' not
# found"). Passing the plugin directory explicitly avoids that toolchain issue. With full Xcode the
# extra flag is harmless.
set -euo pipefail
cd "$(dirname "$0")/.."

TOOLCHAIN_USR="$(dirname "$(dirname "$(xcrun --find swift)")")"
PLUGIN_DIR="$TOOLCHAIN_USR/lib/swift/host/plugins/testing"
EXTRA=()
if [ -d "$PLUGIN_DIR" ]; then
    EXTRA=(-Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR")
fi

exec swift test "${EXTRA[@]}" "$@"
