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

stylua --check lua plugin
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
  "api repos/owner/repo/pulls/123/comments?per_page=100")
    printf '[{"id":1,"path":"file.txt","line":2,"body":"Needs review","user":{"login":"reviewer"}},{"id":2,"path":"file.txt","line":4,"body":"Check final line","user":{"login":"reviewer"}}]\n'
    ;;
  "api graphql")
    args="$*"
    if [[ "$args" == *"viewerViewedState"* ]]; then
      printf '{"data":{"repository":{"pullRequest":{"id":"PR_node","files":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"path":"file.txt","viewerViewedState":"VIEWED"}]}}}}}\n'
    elif [[ "$args" == *"pullRequest(number"* ]]; then
      printf '{"data":{"repository":{"pullRequest":{"id":"PR_node"}}}}\n'
    elif [[ "$args" == *"markFileAsViewed"* ]]; then
      printf '{"data":{"markFileAsViewed":{"clientMutationId":null}}}\n'
    elif [[ "$args" == *"unmarkFileAsViewed"* ]]; then
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
git add file.txt
git commit -q -m base
git checkout -q -b feature
printf 'one\ntwo\n\nbase changed\n' > file.txt
git add file.txt
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
