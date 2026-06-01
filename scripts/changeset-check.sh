#!/usr/bin/env bash
set -euo pipefail

base_ref="${BASE_REF:-origin/main}"

fail() {
  echo "changeset-check: $*" >&2
  exit 1
}

if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
  echo "changeset-check: base ref $base_ref not available; skipping"
  exit 0
fi

mapfile -t changed_files < <(git diff --name-only "$base_ref"...HEAD)
if [[ "${#changed_files[@]}" -eq 0 ]]; then
  echo "changeset-check: no changed files"
  exit 0
fi

needs_release_note=0
has_release_note=0
has_release_commit=0

for path in "${changed_files[@]}"; do
  case "$path" in
    .changeset/*.md)
      if [[ "$path" != ".changeset/README.md" ]]; then
        has_release_note=1
      fi
      ;;
    CHANGELOG.md)
      has_release_note=1
      ;;
  esac

  case "$path" in
    lua/*|plugin/*|scripts/*|devenv.nix|devenv.yaml|devenv.lock|stylua.toml|.github/workflows/*|release-please-config.json|.release-please-manifest.json)
      needs_release_note=1
      ;;
  esac
done

if git log --format=%s "$base_ref"..HEAD | grep -Eq '^(feat|fix|perf)(\([^)]+\))?!?: '; then
  has_release_commit=1
fi

if git log --format=%B "$base_ref"..HEAD | grep -Eq '(^BREAKING CHANGE:|^BREAKING-CHANGE:)'; then
  has_release_commit=1
fi

if [[ "$needs_release_note" -eq 0 ]]; then
  echo "changeset-check: docs-only or metadata-only change"
  exit 0
fi

if [[ "$has_release_note" -eq 1 ]]; then
  echo "changeset-check: release note present"
  exit 0
fi

if [[ "$has_release_commit" -eq 1 ]]; then
  echo "changeset-check: release-bearing conventional commit present"
  exit 0
fi

fail "release-impacting changes need a .changeset/*.md file, CHANGELOG.md update, or release-bearing conventional commit"
