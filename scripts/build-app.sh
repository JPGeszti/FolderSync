#!/bin/bash
# Builds a locally installable, sandboxed FolderSync.app.
#
#   scripts/build-app.sh            → build/FolderSync.app (universal: Apple silicon + Intel, ad-hoc signed)
#   VERSION=1.2.0 scripts/build-app.sh                                  → stamps that version into the app
#   ARCHS=arm64 scripts/build-app.sh                                    → faster single-architecture build
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh   → signed with your identity
#
# The bundle is signed with Resources/FolderSync.entitlements: App Sandbox, user-selected folders,
# app-scoped bookmarks — and no network entitlement.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/FolderSync.app"
IDENTITY="${SIGN_IDENTITY:--}"
read -r -a ARCH_LIST <<< "${ARCHS:-arm64 x86_64}"
ARCH_FLAGS=()
for a in "${ARCH_LIST[@]}"; do ARCH_FLAGS+=(--arch "$a"); done

swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --product FolderSync
BIN="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)/FolderSync"
for a in "${ARCH_LIST[@]}"; do lipo "$BIN" -verify_arch "$a"; done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FolderSync"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -n "${VERSION:-}" ]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
fi

codesign --force --options runtime --timestamp=none \
    --entitlements Resources/FolderSync.entitlements \
    --sign "$IDENTITY" "$APP"

codesign --verify --strict --verbose=2 "$APP"
echo
echo "Entitlements embedded in the signed app:"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - || true
echo
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/FolderSync"), version $(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist"))"
echo "Install: cp -R \"$APP\" /Applications/   or package it with scripts/make-dmg.sh"
