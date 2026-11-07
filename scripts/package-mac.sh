#!/bin/bash
# Builds a release DMG: dist/MDReader-<version>-mac.dmg (universal: Apple silicon + Intel).
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-mac.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Release/MDReader.app/Contents/Info.plist)
APP="$HOME/Library/Caches/MDReader-build/Build/Products/Release/MDReader.app"
mkdir -p dist
DMG="dist/MDReader-$VERSION-mac.dmg"
rm -f "$DMG"
DMGBUILD=$(command -v dmgbuild || echo "$(python3 -m site --user-base)/bin/dmgbuild")
if [ -x "$DMGBUILD" ]; then
  # Styled window: drag-to-install arrow + how to allow the app on first launch.
  swift scripts/make-dmg-background.swift build/dmg >/dev/null
  # Clean copy outside the (possibly iCloud-synced) project: Finder/iCloud attributes on the
  # bundle would break strict code-signature checks ("damaged app" on users' Macs).
  CLEAN=$(mktemp -d)
  ditto --noextattr --norsrc "$APP" "$CLEAN/MDReader.app"
  "$DMGBUILD" -s mac/dmg/settings.py -D app="$CLEAN/MDReader.app" -D bg="$PWD/build/dmg/background.png" \
    -D readme="$PWD/mac/dmg/安装说明.txt" "MDReader $VERSION" "$DMG"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$CLEAN/MDReader.app" 2>/dev/null || true
  rm -rf "$CLEAN"
else
  echo "dmgbuild not found (pip3 install dmgbuild): building a plain DMG"
  STAGE=$(mktemp -d)
  ditto "$APP" "$STAGE/MDReader.app"
  ln -s /Applications "$STAGE/Applications"
  cp "mac/dmg/安装说明.txt" "$STAGE/"
  hdiutil create -quiet -volname "MDReader $VERSION" -srcfolder "$STAGE" -format ULFO -o "$DMG"
  rm -rf "$STAGE"
fi
# Never ship a DMG whose app fails signature verification ("damaged" on users' Macs).
CHECK=$(mktemp -d)
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$CHECK" "$DMG"
codesign --verify --deep --strict "$CHECK/MDReader.app" || { hdiutil detach -quiet "$CHECK"; echo "Signature check failed"; exit 1; }
hdiutil detach -quiet "$CHECK"
echo "Packaged $DMG ($(du -h "$DMG" | cut -f1))"
