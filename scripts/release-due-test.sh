#!/usr/bin/env bash
# Tests scripts/release-due.sh (and scripts/last-release.sh, which it asks)
# against a throwaway repository: which changes since the last release make
# a release, and which do not, with the release tagged as CI tags it, on a
# child of the released trunk commit that adds nix/release.json, or as it
# was tagged before, on the trunk commit itself. Run by mise run check.
set -euo pipefail
unset CDPATH

src=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Nothing from the user's git config: no signing key, no hooks, no agent.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export RELEASE_PATHS="src packaging flake.nix"

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# A repository whose one commit is released, its tag as CI makes it: a
# commit of its own, on no branch, whose parent is the trunk commit and
# which adds nix/release.json. `fresh old` tags the trunk commit itself, as
# releases were tagged before.
fresh() {
    rm -rf "$work/repo"
    mkdir -p "$work/repo/scripts" "$work/repo/src" "$work/repo/packaging"
    cd "$work/repo"
    git init -q -b trunk
    cp "$src/release-due.sh" "$src/last-release.sh" scripts/
    echo 'const x = 1;' > src/main.zig
    echo '[Service]' > packaging/glim.service
    echo '{ }' > flake.nix
    echo lock > flake.lock
    echo readme > README.md
    git add -A
    git commit -qm base
    if [ "${1:-}" = old ]; then
        git tag v0.1.1
    else
        release v0.1.1
    fi
}

# release TAG: tags HEAD's release as CI does, on a child commit holding
# nix/release.json, and leaves trunk checked out where it was.
release() {
    git checkout -q --detach
    mkdir -p nix
    echo "{\"version\": \"${1#v}\"}" > nix/release.json
    # Even a release commit that touched a release path must not count:
    # release-due diffs from the tag's parent.
    echo 'const x = 2; // as the tag sees it' > src/main.zig
    git add -A
    git commit -qm "Release $1"
    git tag "$1"
    git checkout -q trunk
}

# expect WANT DESCRIPTION: release-due.sh's output and status agree with WANT.
expect() {
    local want=$1 what=$2 out status=0
    git add -A
    git commit -qm "$what" "${@:3}"
    out=$(scripts/release-due.sh) || status=$?
    case $want in
    true) [ "$out" = true ] && [ $status -eq 0 ] || fail "$what: want a release, got '$out' (exit $status)" ;;
    false) [ "$out" = false ] && [ $status -eq 1 ] || fail "$what: want no release, got '$out' (exit $status)" ;;
    esac
}

fresh
echo 'const x = 3;' > src/main.zig
expect true "a change to the source"

fresh
echo '{ x = 1; }' > flake.nix
expect true "a change to flake.nix"

fresh
echo readme2 > README.md
echo lock2 > flake.lock
expect false "the README and flake.lock"

fresh
git tag -d v0.1.1 >/dev/null
echo readme2 > README.md
expect true "no release tag yet"

fresh
expect false "nothing since the release (an empty commit)" --allow-empty

fresh old
echo readme2 > README.md
expect false "the README, since a release tagged on trunk itself"

fresh old
echo 'const x = 3;' > src/main.zig
expect true "the source, since a release tagged on trunk itself"

# A tagged-on-trunk release, then a tagged-on-a-child one: the newer is the
# last, so only what changed since it counts.
fresh old
echo 'const x = 3;' > src/main.zig
git commit -qam "source"
release v0.2.7
echo readme2 > README.md
expect false "the README, since the newer of an old-style and a new-style release"

# A release made from a commit after HEAD (trunk checked out behind it) is
# not HEAD's last release.
fresh
echo 'const x = 3;' > src/main.zig
git commit -qam "source"
release v0.2.9
git checkout -q --detach HEAD~1
echo readme2 > README.md
expect false "the README, behind a later release"

if [ $failures -gt 0 ]; then
    exit 1
fi
echo "release-due: ok"
