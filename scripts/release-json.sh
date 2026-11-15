#!/usr/bin/env bash
# Prints nix/release.json for a release: its version, and for each Nix
# system the URL of its release tarball and the tarball's hash in the SRI
# form fetchurl takes. nix/package.nix is that tarball fetched and laid
# out, not a build from source, so a flake pinned at
# github:danielbodart/glim/v<V> gives the very glim the release carries,
# saying it is V.
#
# usage: scripts/release-json.sh VERSION SHA256SUMS
#
# SHA256SUMS is the one `mise run dist` wrote: the tarball must be in it
# exactly once. CI's release job commits the output as the tag's own
# commit, a child of the released trunk commit (ci.yml's release job says
# why); scripts/nix-local-release.sh writes one for a tarball built here,
# for the NixOS VM test.
set -euo pipefail
unset CDPATH

if [ $# -ne 2 ]; then
    echo "usage: scripts/release-json.sh VERSION SHA256SUMS" >&2
    exit 2
fi
version=$1
sums=$2

if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "release-json: '$version' is not MAJOR.MINOR.PATCH" >&2
    exit 2
fi

# Each tarball and the Nix system it serves, in the order they are written.
# Razer's laptops are all x86_64.
pairs=(glim-linux-x86_64.tar.gz:x86_64-linux)

# A hex SHA-256 as SRI, sha256-<base64 of the 32 bytes>, without nix (the
# release job has none): bash's printf writes each \xHH as its byte.
sri() {
    local hex=$1 esc='' i
    for ((i = 0; i < ${#hex}; i += 2)); do esc+="\\x${hex:i:2}"; done
    printf 'sha256-%s' "$(printf '%b' "$esc" | base64 | tr -d '\n')"
}

printf '{\n  "version": "%s",\n  "assets": {\n' "$version"
n=0
for pair in "${pairs[@]}"; do
    name=${pair%%:*}
    system=${pair#*:}
    mapfile -t hex < <(awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }' "$sums")
    if [ ${#hex[@]} -ne 1 ] || ! [[ ${hex[0]} =~ ^[0-9a-f]{64}$ ]]; then
        echo "release-json: want one sha256 for $name in $sums, found ${#hex[@]}" >&2
        exit 1
    fi
    n=$((n + 1))
    sep=,
    [ $n -lt ${#pairs[@]} ] || sep=
    printf '    "%s": {\n      "url": "https://github.com/danielbodart/glim/releases/download/v%s/%s",\n      "hash": "%s"\n    }%s\n' \
        "$system" "$version" "$name" "$(sri "${hex[0]}")" "$sep"
done
printf '  }\n}\n'
