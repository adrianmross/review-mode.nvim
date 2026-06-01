#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$repo_root/.cache}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$repo_root/.local/state}"
mkdir -p "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

nvim --headless -u NONE -i NONE \
  -c "lua assert(loadfile('lua/pr_review/init.lua'))" \
  -c "lua assert(loadfile('lua/pr_review/integrations/nvim_tree.lua'))" \
  -c qa

help_dir="$(mktemp -d "${TMPDIR:-/tmp}/pr-review-help.XXXXXX")"
cp doc/pr-review.txt "$help_dir/pr-review.txt"
nvim --headless -u NONE -i NONE \
  -c "helptags $help_dir" \
  -c qa

stylua --check lua plugin scripts/fixture.lua scripts/rest_fallback_fixture.lua
git diff --check

tmp="$(mktemp -d "${TMPDIR:-/tmp}/pr-review-nvim-test.XXXXXX")"
mkdir -p "$tmp/bin" "$tmp/repo" "$tmp/cache" "$tmp/state"

cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

case "$1 $2" in
  "pr view")
    printf '{"baseRefName":"main","headRefOid":"abc123","number":123}\n'
    ;;
  "repo view")
    printf 'owner/repo\n'
    ;;
  "api repos/owner/repo/pulls/123/comments?per_page=100"|"api repos/owner/repo/pulls/123/comments?per_page=100&page=1")
    printf '[{"id":1,"path":"file.txt","line":2,"body":"Needs review","user":{"login":"reviewer"}},{"id":2,"path":"file.txt","line":4,"body":"Check final line","user":{"login":"reviewer"}}]\n'
    ;;
  "api graphql")
    args="$*"
    if [[ "$args" == *"viewerViewedState"* ]]; then
      printf '{"data":{"repository":{"pullRequest":{"id":"PR_node","files":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"path":"file.txt","viewerViewedState":"VIEWED"}]}}}}}\n'
    elif [[ "$args" == *"reviewThreads"* ]]; then
      if [[ "${PR_REVIEW_FORCE_REST_COMMENTS:-}" == "1" ]]; then
        echo "forced reviewThreads failure" >&2
        exit 1
      fi
      printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"thread_1","path":"file.txt","line":2,"originalLine":2,"startLine":null,"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"id":"comment_1","databaseId":1,"path":"file.txt","line":2,"originalLine":2,"startLine":null,"body":"Needs review","author":{"login":"reviewer"}}]}},{"id":"thread_2","path":"file.txt","line":4,"originalLine":4,"startLine":null,"isResolved":true,"isOutdated":false,"comments":{"nodes":[{"id":"comment_2","databaseId":2,"path":"file.txt","line":4,"originalLine":4,"startLine":null,"body":"Check final line","author":{"login":"reviewer"}}]}}]}}}}}\n'
    elif [[ "$args" == *"pullRequest(number"* ]]; then
      printf '{"data":{"repository":{"pullRequest":{"id":"PR_node"}}}}\n'
    elif [[ "$args" == *"markFileAsViewed"* ]]; then
      if [[ "${PR_REVIEW_FAIL_MUTATION:-}" == "1" ]]; then
        echo "forced viewed mutation failure" >&2
        exit 1
      fi
      printf '{"data":{"markFileAsViewed":{"clientMutationId":null}}}\n'
    elif [[ "$args" == *"unmarkFileAsViewed"* ]]; then
      if [[ "${PR_REVIEW_FAIL_MUTATION:-}" == "1" ]]; then
        echo "forced viewed mutation failure" >&2
        exit 1
      fi
      printf '{"data":{"unmarkFileAsViewed":{"clientMutationId":null}}}\n'
    else
      echo "unexpected gh graphql args: $*" >&2
      exit 1
    fi
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
GH
chmod +x "$tmp/bin/gh"

cd "$tmp/repo"
git init -q
git config user.email test@example.com
git config user.name Test
git checkout -q -B main
printf 'one\n\nbase\n' > file.txt
mkdir -p nested
printf 'alpha\nbase\nomega\n' > nested/other.txt
git add file.txt nested/other.txt
git commit -q -m base
git checkout -q -b feature
printf 'one\ntwo\n\nbase changed\n' > file.txt
printf 'alpha\nfeature\nomega\n' > nested/other.txt
git add file.txt nested/other.txt
git commit -q -m feature
git remote add origin .
git update-ref refs/remotes/origin/main refs/heads/main

PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/cache" \
XDG_STATE_HOME="$tmp/state" \
GH_REVIEW_REPO=owner/repo \
GH_REVIEW_PR=123 \
GH_REVIEW_BASE=main \
GH_REVIEW_HEAD=abc123 \
PR_REVIEW_PLUGIN_ROOT="$repo_root" \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/fixture.lua"

PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/rest-cache" \
XDG_STATE_HOME="$tmp/rest-state" \
GH_REVIEW_REPO=owner/repo \
GH_REVIEW_PR=123 \
GH_REVIEW_BASE=main \
GH_REVIEW_HEAD=abc123 \
PR_REVIEW_PLUGIN_ROOT="$repo_root" \
PR_REVIEW_FORCE_REST_COMMENTS=1 \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/rest_fallback_fixture.lua"
