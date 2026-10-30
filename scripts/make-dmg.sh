#!/bin/bash
# Packages build/FolderSync.app for download:
#   build/FolderSync-<version>.dmg   disk image: open it and drag FolderSync onto Applications
#   build/FolderSync-<version>.zip   the same app as a zip
#   build/SHA256SUMS.txt             checksums of both
#
# Run scripts/build-app.sh first (VERSION=… there sets the version used in these names).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/FolderSync.app"
[ -d "$APP" ] || { echo "Missing $APP — run scripts/build-app.sh first" >&2; exit 1; }
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
DMG="build/FolderSync-$VERSION.dmg"
ZIP="build/FolderSync-$VERSION.zip"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/FolderSync.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG" "$ZIP"
hdiutil create -volname "FolderSync $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
ditto -c -k --keepParent "$APP" "$ZIP"

(cd build && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS.txt)
cat build/SHA256SUMS.txt
echo "Built $DMG and $ZIP"
