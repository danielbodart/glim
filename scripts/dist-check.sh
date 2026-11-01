#!/usr/bin/env bash
# The release tarball, as `mise run dist` made it, unpacked as install.sh
# finds it: the binary says the version it was built as, prints its udev
# rules, and systemd-analyze verifies both units against it, with ExecStart
# pointed where it was unpacked rather than at /usr/local/bin (install.sh
# needs root and a Blade; the NixOS VM test covers an installed system).
set -euo pipefail

CDPATH='' cd "$(dirname "$0")/.."
tarball=glim-linux-x86_64.tar.gz
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

(sha256sum -c "$tarball.sha256")
tar -C "$work" -xzf "$tarball"
for f in glim install.sh glim.service glim-follow.service glim.conf; do
    [ -f "$work/$f" ] || { echo "dist-check: $f missing from $tarball" >&2; exit 1; }
done

version=$("$work/glim" --version)
[[ $version =~ ^0\.[0-9]+\.[0-9]+$ ]] || { echo "dist-check: glim --version said '$version'" >&2; exit 1; }
"$work/glim" udev-rules | grep -q 'SYSTEMD_WANTS.*glim.service'

units=$work/units
mkdir -p "$units"
for unit in glim.service glim-follow.service; do
    sed "s|/usr/local/bin/glim|$work/glim|" "$work/$unit" > "$units/$unit"
    grep -q "^ExecStart=$work/glim " "$units/$unit"
done
systemd-analyze verify "$units/glim.service"
systemd-analyze --user verify "$units/glim-follow.service"
echo "$tarball (v$version) unpacks and its units verify."
