#!/usr/bin/env bash
# Builds universal release binaries and wraps FreespinApp in build/Freespin.app; also builds build/freespinctl.
# Version comes from $VERSION, else the latest git tag, else 0.0.0-dev.
# SIGN_IDENTITY: codesign identity (default "-" = ad-hoc). A stable identity keeps
# Accessibility / Input Monitoring grants across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

version=${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0-dev)}
version=${version#v}
build_number=$(git rev-list --count HEAD 2>/dev/null || echo 1)
identity=${SIGN_IDENTITY:--}

arches=(--arch arm64 --arch x86_64)
swift build -c release "${arches[@]}" --product FreespinApp
swift build -c release "${arches[@]}" --product freespinctl
products=$(swift build -c release "${arches[@]}" --show-bin-path)

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift

app=build/Freespin.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$products/FreespinApp" "$app/Contents/MacOS/Freespin"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp "$products/freespinctl" build/freespinctl
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Freespin</string>
    <key>CFBundleIdentifier</key><string>dev.nkl.freespin</string>
    <key>CFBundleName</key><string>Freespin</string>
    <key>CFBundleDisplayName</key><string>Freespin</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${version}</string>
    <key>CFBundleVersion</key><string>${build_number}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key><string>Flow finds and connects to your other computers running Freespin on this network.</string>
    <key>NSBonjourServices</key><array><string>_freespin-flow._tcp</string></array>
</dict>
</plist>
PLIST
# Ad-hoc signature unless SIGN_IDENTITY is set; a real identity gets a secure timestamp so it can be notarized.
timestamp=--timestamp=none
[ "$identity" != "-" ] && timestamp=--timestamp
codesign --force --options runtime "$timestamp" --sign "$identity" build/freespinctl
codesign --force --options runtime "$timestamp" --sign "$identity" "$app"
codesign --verify "$app"
echo "Built $app and build/freespinctl (version $version)"
