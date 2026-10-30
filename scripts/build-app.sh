#!/bin/bash
# Builds a locally installable, sandboxed FolderSync.app.
#
#   scripts/build-app.sh            → build/FolderSync.app (ad-hoc signed)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh   → signed with your identity
#
# The bundle is signed with Resources/FolderSync.entitlements: App Sandbox, user-selected folders,
# app-scoped bookmarks — and no network entitlement.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/FolderSync.app"
IDENTITY="${SIGN_IDENTITY:--}"

swift build -c "$CONFIG" --arch arm64 --product FolderSync
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/FolderSync"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FolderSync"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --options runtime --timestamp=none \
    --entitlements Resources/FolderSync.entitlements \
    --sign "$IDENTITY" "$APP"

codesign --verify --strict --verbose=2 "$APP"
echo
echo "Entitlements embedded in the signed app:"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - || true
echo
echo "Built $APP"
echo "Install: cp -R \"$APP\" /Applications/"
