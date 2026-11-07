#!/bin/bash
# Regenerates every icon: macOS .icns, Windows .ico, start-page PNG. pngquant (optional) shrinks them.
set -euo pipefail
cd "$(dirname "$0")/.."
swift scripts/make-icons.swift build/icons
if command -v pngquant >/dev/null; then
  for f in build/icons/AppIcon.iconset/*.png; do pngquant --quality 65-85 --speed 1 --strip --force --ext .png "$f"; done
  for f in build/icons/MarkdownDoc.iconset/*.png build/icons/appicon-256.png build/icons/*-win/*.png; do
    pngquant --quality 85-98 --speed 1 --strip --force --ext .png "$f"; done
fi
for n in AppIcon MarkdownDoc; do iconutil -c icns "build/icons/$n.iconset" -o "mac/Resources/$n.icns"; done
cp build/icons/appicon-256.png shared/web/appicon.png
mkdir -p win/MDReader/res
python3 scripts/make-ico.py build/icons/AppIcon-win win/MDReader/res/app.ico
python3 scripts/make-ico.py build/icons/MarkdownDoc-win win/MDReader/res/doc.ico
echo "icons updated"
