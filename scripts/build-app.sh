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

# freespinctl carries an embedded Info.plist: when it runs as a LaunchAgent (`freespinctl daemon`) it is
# its own app as far as TCC is concerned, so it needs a bundle identifier and the Local Network strings.
mkdir -p build
cat > build/freespinctl-Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.nkl.freespin.ctl</string>
    <key>CFBundleName</key><string>freespinctl</string>
    <key>CFBundleShortVersionString</key><string>${version}</string>
    <key>CFBundleVersion</key><string>${build_number}</string>
    <key>NSLocalNetworkUsageDescription</key><string>Flow finds and connects to your other computers running Freespin on this network.</string>
    <key>NSBonjourServices</key><array><string>_freespin-flow._tcp</string></array>
</dict>
</plist>
PLIST
swift build -c release "${arches[@]}" --product freespinctl \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PWD/build/freespinctl-Info.plist"
products=$(swift build -c release "${arches[@]}" --show-bin-path)

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift

app=build/Freespin.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$products/FreespinApp" "$app/Contents/MacOS/Freespin"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp "$products/freespinctl" build/freespinctl

# Sparkle: ditto keeps the framework's symlinks. The XPC services are only needed by sandboxed apps.
mkdir -p "$app/Contents/Frameworks"
ditto "$products/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
  "$app/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/Freespin"

# Updates come from the newest GitHub release's appcast.xml, signed with this EdDSA key (public half).
feed_url=https://github.com/nklmilojevic/freespin/releases/latest/download/appcast.xml
sparkle_public_key=${SPARKLE_PUBLIC_KEY:-XRx7N1Dj3HGcSCvbUn52xOVQiwjpXoctJmni7BVZVRk=}

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
    <key>SUFeedURL</key><string>${feed_url}</string>
    <key>SUPublicEDKey</key><string>${sparkle_public_key}</string>
    <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST
# Ad-hoc signature unless SIGN_IDENTITY is set; a real identity gets the hardened runtime and a secure
# timestamp so it can be notarized. Ad-hoc builds skip the hardened runtime: its library validation needs a
# team ID, which an ad-hoc signature lacks, so Sparkle.framework wouldn't load.
# Inside out and without --deep, as Sparkle's docs ask.
flags=(--timestamp=none)
[ "$identity" != "-" ] && flags=(--timestamp --options runtime)
sign() { codesign --force "${flags[@]}" --sign "$identity" "$@"; }
sign --identifier dev.nkl.freespin.ctl build/freespinctl
sparkle="$app/Contents/Frameworks/Sparkle.framework"
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"
sign "$app"
codesign --verify --strict "$app"
echo "Built $app and build/freespinctl (version $version)"
