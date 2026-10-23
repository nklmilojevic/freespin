#!/usr/bin/env bash
# Builds the app and CLI, then packages dist/Freespin-<version>.dmg and dist/freespinctl-<version>-macos.tar.gz.
# Notarizes (and staples the app and DMG) when SIGN_IDENTITY is a Developer ID and one of these is set:
#   NOTARY_PROFILE                                  a `xcrun notarytool store-credentials` keychain profile
#   NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER_ID   an App Store Connect API key (.p8 path), as in CI
set -euo pipefail
cd "$(dirname "$0")/.."

notary=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
  notary=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY:-}" ]; then
  notary=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}")
fi
if [ ${#notary[@]} -gt 0 ] && [ "${SIGN_IDENTITY:--}" = "-" ]; then
  echo "notarization needs SIGN_IDENTITY set to a Developer ID" >&2
  exit 1
fi

# Submits a .zip or .dmg and waits; fails with Apple's log unless it is accepted.
notarize() {
  [ ${#notary[@]} -gt 0 ] || return 0
  local out status id
  out=$(xcrun notarytool submit "$1" "${notary[@]}" --wait --output-format json)
  status=$(plutil -extract status raw -o - - <<<"$out")
  if [ "$status" != Accepted ]; then
    id=$(plutil -extract id raw -o - - <<<"$out")
    echo "notarization of $1: $status" >&2
    xcrun notarytool log "$id" "${notary[@]}" >&2 || true
    exit 1
  fi
  echo "notarized $1"
}

./scripts/build-app.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Freespin.app/Contents/Info.plist)

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

# A bare binary can't be stapled; Gatekeeper finds its ticket online.
ditto -c -k build/freespinctl "$staging/freespinctl.zip"
notarize "$staging/freespinctl.zip"
ditto -c -k --keepParent build/Freespin.app "$staging/Freespin.zip"
notarize "$staging/Freespin.zip"
[ ${#notary[@]} -gt 0 ] && xcrun stapler staple build/Freespin.app

mkdir -p dist "$staging/dmg"
ditto build/Freespin.app "$staging/dmg/Freespin.app"
ln -s /Applications "$staging/dmg/Applications"

# APFS with LZFSE compression, as Sparkle recommends for DMG updates.
dmg=dist/Freespin-${version}.dmg
rm -f "$dmg"
hdiutil create -volname "Freespin ${version}" -srcfolder "$staging/dmg" -fs APFS -format ULFO -ov "$dmg" >/dev/null
if [ "${SIGN_IDENTITY:--}" != "-" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
fi
notarize "$dmg"
[ ${#notary[@]} -gt 0 ] && xcrun stapler staple "$dmg"

tarball=dist/freespinctl-${version}-macos.tar.gz
tar -czf "$tarball" -C build freespinctl

(cd dist && shasum -a 256 "$(basename "$dmg")" "$(basename "$tarball")" > SHA256SUMS)
echo "Packaged $dmg and $tarball"
