#!/bin/bash
# MDReader installer for macOS.
#   curl -fsSL https://raw.githubusercontent.com/x2724009/MDReader/main/install.sh | bash
#
# Downloads the latest release DMG from GitHub with curl and copies the app to /Applications
# (or ~/Applications if /Applications isn't writable). Files fetched by curl are not marked
# "downloaded from the internet", so the app opens without the Gatekeeper prompt that
# browser downloads of this (not yet notarized) app get.
set -euo pipefail

REPO="x2724009/MDReader"
DEST="${MDREADER_DEST:-/Applications}"     # override for testing
if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi

say() { printf '\033[1;35m==>\033[0m %s\n' "$*"; }

[ "$(uname)" = "Darwin" ] || { echo "MDReader for macOS only. Windows builds: https://github.com/$REPO/releases/latest"; exit 1; }

say "Finding the latest MDReader release…"
URL=$(curl -fsSL --retry 4 --retry-all-errors --retry-delay 2 "https://api.github.com/repos/$REPO/releases/latest" \
      | grep -o '"browser_download_url": *"[^"]*-mac\.dmg"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/')
[ -n "$URL" ] || { echo "Could not find a macOS download. See https://github.com/$REPO/releases"; exit 1; }

TMP=$(mktemp -d)
cleanup() { hdiutil detach -quiet "$TMP/mnt" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

say "Downloading $(basename "$URL")…"
curl -fL --retry 4 --retry-all-errors --retry-delay 2 --progress-bar "$URL" -o "$TMP/MDReader.dmg"

say "Installing to $DEST…"
mkdir -p "$TMP/mnt"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$TMP/mnt" "$TMP/MDReader.dmg"
[ -n "${MDREADER_DEST:-}" ] || osascript -e 'quit app "MDReader"' >/dev/null 2>&1 || true
rm -rf "$DEST/MDReader.app"
ditto "$TMP/mnt/MDReader.app" "$DEST/MDReader.app"

# Register the app and its Quick Look extensions (thumbnails, space-bar preview).
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -f -R "$DEST/MDReader.app" >/dev/null 2>&1 || true
pluginkit -a "$DEST/MDReader.app/Contents/PlugIns/MDReaderThumbnail.appex" >/dev/null 2>&1 || true
pluginkit -a "$DEST/MDReader.app/Contents/PlugIns/MDReaderPreview.appex" >/dev/null 2>&1 || true
qlmanage -r >/dev/null 2>&1 || true

say "Done: $DEST/MDReader.app"
if [ -z "${MDREADER_DEST:-}" ]; then open "$DEST/MDReader.app"; fi
