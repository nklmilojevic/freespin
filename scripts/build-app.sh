#!/usr/bin/env bash
# Builds build/Freespin.app from the SwiftPM FreespinApp target.
# SIGN_IDENTITY: codesign identity (default "-" = ad-hoc). A stable identity keeps
# Accessibility / Input Monitoring grants across rebuilds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
IDENTITY="${SIGN_IDENTITY:--}"
APP="$ROOT/build/Freespin.app"
VERSION="${VERSION:-0.1.0}"

swift build --package-path "$ROOT" -c "$CONFIG" --product FreespinApp
BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)/FreespinApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Freespin"
[ -f "$ROOT/Resources/AppIcon.icns" ] || (cd "$ROOT" && swift scripts/make-icon.swift)
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Freespin</string>
  <key>CFBundleIdentifier</key><string>dev.nkl.freespin</string>
  <key>CFBundleName</key><string>Freespin</string>
  <key>CFBundleDisplayName</key><string>Freespin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --verbose=1 "$APP"
echo "built $APP"
