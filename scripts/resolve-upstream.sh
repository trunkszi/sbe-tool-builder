#!/usr/bin/env bash
# Resolve which upstream SBE revision to build.
#
# Usage: scripts/resolve-upstream.sh [REF]
#
# REF may be a release tag (e.g. 1.40.1), a branch (e.g. master) or a commit.
# When REF is empty the newest upstream release tag is selected.
#
# Prints KEY=VALUE lines on stdout:
#   ref      the ref that was requested or selected
#   commit   the resolved commit sha
#   version  release version string (equals the tag for tag builds)
#   tag      the release tag this build publishes to
#   prerelease  true for non-tag builds
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/aeron-io/simple-binary-encoding.git}"
ref="${1:-${UPSTREAM_REF:-}}"

release_tag_re='^[0-9]+\.[0-9]+\.[0-9]+$'

if [[ -z "$ref" ]]; then
  ref="$(git ls-remote --tags --refs "$UPSTREAM_REPO" \
    | awk -F/ '{print $NF}' \
    | grep -E "$release_tag_re" \
    | sort -V \
    | tail -n 1)"
  [[ -n "$ref" ]] || { echo "no release tag found in $UPSTREAM_REPO" >&2; exit 1; }
fi

resolve_remote() {
  # Prefer the peeled commit for annotated tags.
  git ls-remote "$UPSTREAM_REPO" "refs/tags/$1^{}" "refs/tags/$1" "refs/heads/$1" \
    | awk '{print $1}' | head -n 1
}

commit="$(resolve_remote "$ref")"
if [[ -z "$commit" ]]; then
  if [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]]; then
    commit="$ref"
  else
    echo "ref '$ref' not found in $UPSTREAM_REPO" >&2
    exit 1
  fi
fi

if [[ "$ref" =~ $release_tag_re ]]; then
  version="$ref"
  prerelease=false
else
  # Branch or commit build: derive the version from the upstream tree.
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  git -C "$tmp" init -q
  git -C "$tmp" fetch -q --depth 1 "$UPSTREAM_REPO" "$commit"
  base="$(git -C "$tmp" show FETCH_HEAD:version.txt | tr -d '[:space:]')"
  version="${base}-g${commit:0:7}"
  prerelease=true
fi

printf 'ref=%s\ncommit=%s\nversion=%s\ntag=%s\nprerelease=%s\n' \
  "$ref" "$commit" "$version" "$version" "$prerelease"
