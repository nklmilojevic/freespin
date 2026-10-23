#!/usr/bin/env bash
# Writes dist/appcast.xml for dist/Freespin-<version>.dmg, the feed Sparkle reads from the newest release.
# The EdDSA private key comes from $SPARKLE_PRIVATE_KEY (CI), else from the login keychain.
# usage: scripts/appcast.sh 0.3.0
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: $0 <version>}
version=${version#v}
repo=https://github.com/nklmilojevic/freespin
sparkle_version=2.10.0
sparkle_sha256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c

dmg=dist/Freespin-${version}.dmg
[ -f "$dmg" ] || { echo "missing $dmg (run scripts/dmg.sh first)" >&2; exit 1; }
rm -f dist/appcast.xml

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/sparkle.tar.xz" \
  "https://github.com/sparkle-project/Sparkle/releases/download/${sparkle_version}/Sparkle-${sparkle_version}.tar.xz"
echo "${sparkle_sha256}  $work/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null
mkdir "$work/sparkle" "$work/updates"
tar -xf "$work/sparkle.tar.xz" -C "$work/sparkle"

# Only the DMG: generate_appcast treats every archive in the folder as an update, the CLI tarball too.
cp "$dmg" "$work/updates/"
# Release notes: this version's CHANGELOG.md section ("## v0.3.0 - date"), when there is one.
notes="$work/updates/Freespin-${version}.md"
awk -v head="## v${version} " 'index($0, head) == 1 { on = 1; next } /^## / { if (on) exit } on' CHANGELOG.md > "$notes"
[ -s "$notes" ] || rm -f "$notes"

args=(--download-url-prefix "${repo}/releases/download/v${version}/"
  --full-release-notes-url "${repo}/releases/tag/v${version}"
  --link "$repo" --embed-release-notes --maximum-deltas 0 -o dist/appcast.xml)
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$work/sparkle/bin/generate_appcast" --ed-key-file - "${args[@]}" "$work/updates"
else
  "$work/sparkle/bin/generate_appcast" "${args[@]}" "$work/updates"
fi
# With a key that doesn't match the app's SUPublicEDKey, generate_appcast only warns and leaves the update
# unsigned, which every client would reject.
grep -q 'sparkle:edSignature=' dist/appcast.xml || { echo "appcast.xml is unsigned: wrong SPARKLE_PRIVATE_KEY?" >&2; exit 1; }
echo "Wrote dist/appcast.xml for ${version}"
