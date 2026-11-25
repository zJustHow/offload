#!/bin/bash
# Packs build/Offload.app into build/Offload-<version>.dmg with an Applications shortcut.
# Usage: Scripts/make_dmg.sh        (run Scripts/make_app.sh first, or pass --build)
set -euo pipefail
cd "$(dirname "$0")/.."
[ "${1:-}" = "--build" ] && Scripts/make_app.sh release
APP="build/Offload.app"
[ -d "$APP" ] || { echo "error: $APP not found; run Scripts/make_app.sh first" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Offload-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Offload" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
