#!/usr/bin/env bash
set -euo pipefail

manifest=".release-please-manifest.json"
changelog="CHANGELOG.md"

fail() {
  echo "release-check: $*" >&2
  exit 1
}

[[ -f "$manifest" ]] || fail "missing $manifest"
[[ -f "$changelog" ]] || fail "missing $changelog"

version="$(awk -F'"' '/"\."/ { print $4; exit }' "$manifest")"
[[ -n "$version" ]] || fail "could not read current version from $manifest"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || fail "invalid semver: $version"

tag="v${version}"
grep -Eq "^## ${tag}($| - )" "$changelog" || fail "$changelog is missing section ## $tag"

notes="$(bash scripts/release-notes.sh "$tag" | sed '/^[[:space:]]*$/d')"
[[ -n "$notes" ]] || fail "$changelog section $tag is empty"

current_tag="${GITHUB_REF_NAME:-}"
if [[ -z "$current_tag" ]]; then
  current_tag="$(git describe --tags --exact-match HEAD 2>/dev/null || true)"
fi

if [[ -n "$current_tag" && "$current_tag" == v* && "$current_tag" != "$tag" ]]; then
  fail "tag $current_tag does not match manifest version $tag"
fi

echo "release-check: $tag ok"
