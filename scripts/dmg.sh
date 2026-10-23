#!/usr/bin/env bash
# Builds the app and CLI, then packages dist/Freespin-<version>.dmg and dist/freespinctl-<version>-macos.tar.gz.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Freespin.app/Contents/Info.plist)

mkdir -p dist
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp -R build/Freespin.app "$staging/Freespin.app"
ln -s /Applications "$staging/Applications"

dmg=dist/Freespin-${version}.dmg
rm -f "$dmg"
hdiutil create -volname "Freespin ${version}" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
if [ "${SIGN_IDENTITY:--}" != "-" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
fi

tarball=dist/freespinctl-${version}-macos.tar.gz
tar -czf "$tarball" -C build freespinctl

(cd dist && shasum -a 256 "$(basename "$dmg")" "$(basename "$tarball")" > SHA256SUMS)
echo "Packaged $dmg and $tarball"
