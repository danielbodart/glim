#!/usr/bin/env bash
# Whether the commit checked out is due a release: prints true and exits 0
# if anything in RELEASE_PATHS (mise.toml's [env], which `mise run
# release-due` sets) changed since the last release, else prints false and
# exits 1. With no release yet, it is due. CI's release job and the weekly
# update ask it: `if mise run release-due; then ...`.
#
# The last release is the trunk commit its tag released, the tag's parent,
# not the tag's own commit (scripts/last-release.sh): that adds
# nix/release.json, which is the release's output, not its input.
set -euo pipefail
unset CDPATH

: "${RELEASE_PATHS:?RELEASE_PATHS is unset: run this as mise run release-due}"
cd "$(git rev-parse --show-toplevel)"

read -ra paths <<<"$RELEASE_PATHS"
if ! read -r _ last < <(scripts/last-release.sh); then
    echo true
    exit 0
fi
if [ -n "$(git diff --name-only "$last" HEAD -- "${paths[@]}")" ]; then
    echo true
else
    echo false
    exit 1
fi
