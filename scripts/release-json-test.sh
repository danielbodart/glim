#!/usr/bin/env bash
# Tests scripts/release-json.sh against v0.13.10's real SHA256SUMS: the
# file it writes is the one flake.nix reads, with the tarball's hash in the
# SRI form `nix hash convert --hash-algo sha256 --to sri` gives (worked out
# with it once, and written here, since check runs where there may be no
# nix), and a SHA256SUMS without the tarball, or a version that is not
# one, makes nothing. Run by mise run check.
set -euo pipefail
unset CDPATH

script=$(cd "$(dirname "$0")" && pwd)/release-json.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

cat >"$work/SHA256SUMS" <<'SUMS'
1964b3143300af3f6bb1cb7cf130c288e9b2761bac601e6294d45e438d2825b7  glim-linux-x86_64.tar.gz
03791b333a75a6ae195c987c75f4ecbf14a0c30b13792254dbe4f2a241018c7e  install.sh
SUMS

cat >"$work/want.json" <<'JSON'
{
  "version": "0.13.10",
  "assets": {
    "x86_64-linux": {
      "url": "https://github.com/danielbodart/glim/releases/download/v0.13.10/glim-linux-x86_64.tar.gz",
      "hash": "sha256-GWSzFDMArz9rsct88TDCiOmydhusYB5ilNReQ40oJbc="
    }
  }
}
JSON

if ! "$script" 0.13.10 "$work/SHA256SUMS" >"$work/got.json"; then
    fail "a release's SHA256SUMS: refused"
elif ! diff -u "$work/want.json" "$work/got.json"; then
    fail "a release's SHA256SUMS: not the release.json flake.nix wants"
fi

grep -v tar.gz "$work/SHA256SUMS" >"$work/short"
if "$script" 0.13.10 "$work/short" >/dev/null 2>&1; then
    fail "a SHA256SUMS without the tarball: accepted"
fi

if "$script" v0.13.10 "$work/SHA256SUMS" >/dev/null 2>&1; then
    fail "a version with a v: accepted"
fi

if [ $failures -gt 0 ]; then
    exit 1
fi
echo "release-json: ok"
