#!/usr/bin/env bash
# The identity a client build should claim.
#
# The commit, plus "-dirty" only when a file that actually goes into the binary
# has uncommitted changes. Repository-wide dirtiness is wrong here: an edit to a
# document elsewhere in the tree would change the expected stamp, and a build
# verified moments earlier would fail its own check for a change that cannot be
# in it.
#
# One shell implementation shared by build.sh and the capture harness.
# crates/ao-client/build.rs necessarily repeats the rule in Rust, because it is
# what bakes the value in; the two are kept in step deliberately and there
# should not be a third.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

sha="$(git rev-parse --short=7 HEAD 2>/dev/null)" || exit 0
[ -z "$sha" ] && exit 0

if [ -n "$(git status --porcelain -- crates assets Cargo.toml Cargo.lock 2>/dev/null)" ]; then
  printf '%s-dirty' "$sha"
else
  printf '%s' "$sha"
fi
