#!/usr/bin/env bash
# Points the Nix package at a published release: nix/release.json gets the version and the SRI hash of
# freespinctl-<version>-macos.tar.gz, taken from the release's SHA256SUMS.
# usage: scripts/update-nix-release.sh 0.3.0
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: $0 <version>}
version=${version#v}
tarball="freespinctl-${version}-macos.tar.gz"

sums=$(gh release download "v${version}" --pattern SHA256SUMS --output -)
hex=$(awk -v f="$tarball" '$2 == f { print $1 }' <<<"$sums")
[ -n "$hex" ] || { echo "no $tarball in the v${version} SHA256SUMS" >&2; exit 1; }
hash="sha256-$(xxd -r -p <<<"$hex" | base64)"

cat > nix/release.json <<JSON
{
  "version": "${version}",
  "hash": "${hash}"
}
JSON
echo "nix/release.json → ${version} (${hash})"
