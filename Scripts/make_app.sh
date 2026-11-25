#!/bin/bash
# Builds build/Offload.app (menu bar app) with the `offload` CLI bundled next to it.
# Usage: Scripts/make_app.sh [debug|release]
#   VERSION=1.2.0 BUILD=45 Scripts/make_app.sh      override the version shown in Finder
#   SIGN_IDENTITY="Developer ID Application: …" Scripts/make_app.sh    sign for distribution
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"      # "-" = ad-hoc: runs on this Mac only
swift build -c "$CONFIG"

APP="build/Offload.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/OffloadApp" "$APP/Contents/MacOS/OffloadApp"
cp ".build/$CONFIG/offload" "$APP/Contents/MacOS/offload"

# The icon is drawn by the same UI code as the app, so it can never drift from it.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
".build/$CONFIG/offload-previews" --icon "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>OffloadApp</string>
  <key>CFBundleIdentifier</key><string>dev.offload</string>
  <key>CFBundleName</key><string>Offload</string>
  <key>CFBundleDisplayName</key><string>Offload</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Everything stays on your Mac unless you choose a hosted model.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Offload reads your calendar to understand your plans and prepare suggestions. Events are summarized on this Mac.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Offload reads folders you choose to build your knowledge base.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Offload reads folders you choose to build your knowledge base.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Offload reads folders you choose to build your knowledge base.</string>
</dict></plist>
PLIST

# Ad-hoc signing is enough to run locally. For distribution pass SIGN_IDENTITY (a Developer ID
# certificate) and notarize the result: `xcrun notarytool submit … --wait && xcrun stapler staple`.
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - --deep "$APP" >/dev/null 2>&1 || echo "warning: codesign failed; the app will still run locally"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/offload"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null
echo "Built $APP ($VERSION, build $BUILD)"
