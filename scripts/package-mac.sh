#!/bin/bash
# Builds a release DMG: dist/MDReader-<version>-mac.dmg (universal: Apple silicon + Intel).
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-mac.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Release/MDReader.app/Contents/Info.plist)
APP="$HOME/Library/Caches/MDReader-build/Build/Products/Release/MDReader.app"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/MDReader.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
DMG="dist/MDReader-$VERSION-mac.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "MDReader $VERSION" -srcfolder "$STAGE" -format ULFO -o "$DMG"
rm -rf "$STAGE"
echo "Packaged $DMG ($(du -h "$DMG" | cut -f1))"
