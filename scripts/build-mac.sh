#!/bin/bash
# Build MDReader.app (Release) into build/Release/MDReader.app.
# Optional: ./scripts/build-mac.sh --install   → copy to /Applications and register Quick Look extensions.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }

if [ ! -f mac/Resources/AppIcon.icns ]; then
  ./scripts/make-icons.sh
fi

xcodegen generate --quiet
# DerivedData lives outside the (possibly iCloud-synced) project folder: codesign rejects iCloud metadata.
DD="$HOME/Library/Caches/MDReader-build"
xcodebuild -project MDReader.xcodeproj -scheme MDReader -configuration Release \
  -derivedDataPath "$DD" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet

rm -rf build/Release && mkdir -p build/Release
ditto --noextattr --norsrc "$DD/Build/Products/Release/MDReader.app" build/Release/MDReader.app
echo "Built: build/Release/MDReader.app ($(du -sh build/Release/MDReader.app | cut -f1))"

if [ "${1:-}" = "--install" ]; then
  osascript -e 'quit app "MDReader"' 2>/dev/null || true
  rm -rf /Applications/MDReader.app
  ditto "$DD/Build/Products/Release/MDReader.app" /Applications/MDReader.app
  LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSREG" -f -R /Applications/MDReader.app
  pluginkit -a /Applications/MDReader.app/Contents/PlugIns/MDReaderThumbnail.appex
  pluginkit -a /Applications/MDReader.app/Contents/PlugIns/MDReaderPreview.appex
  qlmanage -r >/dev/null 2>&1; qlmanage -r cache >/dev/null 2>&1
  killall -q quicklookd QuickLookUIService 2>/dev/null || true
  echo "Installed to /Applications/MDReader.app"
fi
