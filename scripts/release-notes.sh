#!/usr/bin/env bash
set -euo pipefail

version="${1:-}"
if [[ -z "$version" ]]; then
  version="$(awk -F'"' '/"\."/ { print $4; exit }' .release-please-manifest.json)"
  version="v${version}"
fi

if [[ "$version" != v* ]]; then
  version="v${version}"
fi

awk -v version="$version" '
  BEGIN {
    plain = version
    sub(/^v/, "", plain)
  }
  $0 == "## " version ||
  index($0, "## " version " - ") == 1 ||
  index($0, "## [" version "](") == 1 ||
  index($0, "## [" plain "](") == 1 {
    found = 1
    next
  }
  found && /^## / {
    exit
  }
  found {
    print
  }
  END {
    if (!found) {
      exit 2
    }
  }
' CHANGELOG.md
