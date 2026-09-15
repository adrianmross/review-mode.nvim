#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$repo_root/.cache}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$repo_root/.local/state}"
mkdir -p "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

nvim --headless -u NONE -i NONE \
  -c "lua assert(loadfile('lua/review_mode/init.lua'))" \
  -c "lua assert(loadfile('lua/review_mode/integrations/nvim_tree.lua'))" \
  -c "lua assert(loadfile('lua/review_mode/health.lua'))" \
  -c qa

help_dir="$(mktemp -d "${TMPDIR:-/tmp}/review-mode-help.XXXXXX")"
cp doc/review-mode.txt "$help_dir/review-mode.txt"
nvim --headless -u NONE -i NONE \
  -c "helptags $help_dir" \
  -c qa

# The bundled UI must build on the public API, the same as anyone else's would.
# If one of these needs a plugin internal, the API is missing something: add it
# to review_mode.api rather than reaching around it.
for ui in lua/review_mode/panel.lua lua/review_mode/picker.lua lua/review_mode/integrations/nvim_tree.lua; do
  if grep -nE 'require\("review_mode\.(state|github|viewed|comments|diff|init)"\)' "$ui"; then
    echo "$ui reaches past review_mode.api (see the rule in lua/review_mode/api.lua)" >&2
    exit 1
  fi
done

stylua --check lua plugin scripts/fixture.lua scripts/rest_fallback_fixture.lua
git diff --check
bash scripts/release-check.sh

tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-mode-nvim-test.XXXXXX")"
mkdir -p "$tmp/bin" "$tmp/repo" "$tmp/cache" "$tmp/state"

cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

case "$1 $2" in
  "pr view")
    args="$*"
    if [[ "$args" == *"--json url"* && "$args" == *"-q .url"* ]]; then
      printf 'https://github.com/owner/repo/pull/123\n'
    elif [[ "$args" == *"title,state,isDraft,mergeable,reviewDecision,headRefName,baseRefName,url"* ]]; then
      printf '{"title":"Improve review tools","state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"REVIEW_REQUIRED","headRefName":"feature","baseRefName":"main","url":"https://github.com/owner/repo/pull/123"}\n'
    else
      printf '{"baseRefName":"main","headRefOid":"abc123","number":123}\n'
    fi
    ;;
  "pr checks")
    printf 'validate\tpass\t0\thttps://example.test/checks/validate\n'
    ;;
  "repo view")
    printf 'owner/repo\n'
    ;;
  "api repos/owner/repo/pulls/123/comments?per_page=100"|"api repos/owner/repo/pulls/123/comments?per_page=100&page=1")
    printf '%s\n' '[{"id":1,"path":"file.txt","line":2,"body":"Needs review","user":{"login":"reviewer"},"created_at":"2024-01-02T03:04:05Z","html_url":"https://github.com/owner/repo/pull/123#discussion_r1","author_association":"OWNER","reactions":{"+1":2,"laugh":0,"hooray":1,"heart":0,"rocket":0,"eyes":0,"total_count":3}},{"id":2,"path":"file.txt","line":4,"body":"Check final line","user":{"login":"reviewer"},"created_at":"2024-01-02T03:04:05Z","author_association":"NONE","reactions":{"+1":0,"total_count":0}}]'
    ;;
  "api repos/owner/repo/pulls/123/comments/1/replies")
    args="$*"
    if [[ "$args" == *"--method POST"* ]]; then
      printf '{"id":100,"path":"file.txt","line":2,"body":"replied"}\n'
    else
      echo "unexpected gh replies args: $*" >&2
      exit 1
    fi
    ;;
  "api repos/owner/repo/pulls/123/comments")
    args="$*"
    if [[ "$args" == *"--method POST"* ]]; then
      printf '{"id":99,"path":"file.txt","line":2,"body":"created"}\n'
    else
      echo "unexpected gh comments args: $*" >&2
      exit 1
    fi
    ;;
  "api graphql")
    args="$*"
    if [[ "$args" == *"viewerViewedState"* ]]; then
      printf '{"data":{"repository":{"pullRequest":{"id":"PR_node","files":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"path":"file.txt","viewerViewedState":"VIEWED"}]}}}}}\n'
    elif [[ "$args" == *"resolveReviewThread"* ]]; then
      printf '{"data":{"resolveReviewThread":{"thread":{"id":"thread_1","isResolved":true}}}}\n'
    elif [[ "$args" == *"unresolveReviewThread"* ]]; then
      printf '{"data":{"unresolveReviewThread":{"thread":{"id":"thread_1","isResolved":false}}}}\n'
    elif [[ "$args" == *"reviewThreads"* ]]; then
      if [[ "${REVIEW_MODE_FORCE_REST_COMMENTS:-}" == "1" ]]; then
        echo "forced reviewThreads failure" >&2
        exit 1
      fi
      # printf '%s\n' so the escaped newlines inside comment bodies survive as
      # JSON escapes instead of being expanded into real newlines.
      printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"thread_1","path":"file.txt","line":2,"originalLine":2,"startLine":null,"diffSide":"RIGHT","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"id":"comment_1","databaseId":1,"path":"file.txt","line":2,"originalLine":2,"startLine":null,"createdAt":"2024-01-02T03:04:05Z","url":"https://github.com/owner/repo/pull/123#discussion_r1","state":"SUBMITTED","authorAssociation":"OWNER","viewerDidAuthor":false,"body":"Needs review\n\n```suggestion\ntwo improved\n```","author":{"login":"reviewer"},"reactionGroups":[{"content":"THUMBS_UP","reactors":{"totalCount":2}},{"content":"HOORAY","reactors":{"totalCount":1}},{"content":"EYES","reactors":{"totalCount":0}}]}]}},{"id":"thread_2","path":"file.txt","line":4,"originalLine":4,"startLine":null,"diffSide":"RIGHT","isResolved":true,"isOutdated":false,"comments":{"nodes":[{"id":"comment_2","databaseId":2,"path":"file.txt","line":4,"originalLine":4,"startLine":null,"createdAt":"2024-01-02T03:04:05Z","url":"https://github.com/owner/repo/pull/123#discussion_r2","authorAssociation":"CONTRIBUTOR","body":"Check final line","author":{"login":"reviewer"},"reactionGroups":[]},{"id":"comment_4","databaseId":4,"path":"file.txt","line":4,"originalLine":4,"startLine":null,"createdAt":"2024-01-03T03:04:05Z","url":"https://github.com/owner/repo/pull/123#discussion_r4","authorAssociation":"MEMBER","body":"Fixed in the follow-up commit.","author":{"login":"maintainer"},"reactionGroups":[{"content":"HEART","reactors":{"totalCount":1}}]}]}},{"id":"thread_3","path":"nested/other.txt","line":2,"originalLine":2,"startLine":null,"diffSide":"RIGHT","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"id":"comment_3","databaseId":3,"path":"nested/other.txt","line":2,"originalLine":2,"startLine":null,"createdAt":"2024-01-02T03:04:05Z","url":"https://github.com/owner/repo/pull/123#discussion_r3","authorAssociation":"NONE","body":"Review nested change","author":{"login":"reviewer"},"reactionGroups":[]}]}}]}}}}}'
    elif [[ "$args" == *"pullRequest(number"* ]]; then
      printf '{"data":{"repository":{"pullRequest":{"id":"PR_node"}}}}\n'
    elif [[ "$args" == *"markFileAsViewed"* ]]; then
      if [[ "${REVIEW_MODE_FAIL_MUTATION:-}" == "1" ]]; then
        echo "forced viewed mutation failure" >&2
        exit 1
      fi
      printf '{"data":{"markFileAsViewed":{"clientMutationId":null}}}\n'
    elif [[ "$args" == *"unmarkFileAsViewed"* ]]; then
      if [[ "${REVIEW_MODE_FAIL_MUTATION:-}" == "1" ]]; then
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
printf 'one\n\nbase\nsame1\nsame2\nsame3\nsame4\nsame5\ntail\n' > file.txt
mkdir -p nested
mkdir -p nested/deeper
printf 'alpha\n-- old\nomega\n' > nested/other.txt
printf 'deep\nbase\n' > nested/deeper/more.txt
git add file.txt nested/other.txt nested/deeper/more.txt
git commit -q -m base
git checkout -q -b feature
printf 'one\ntwo\n\nbase changed\nsame1\nsame2\nsame3\nsame4\nsame5\ntail\n' > file.txt
printf 'alpha\n-- new\nomega\n' > nested/other.txt
printf 'deep\nfeature\n' > nested/deeper/more.txt
printf 'new one\nnew two\n' > new.txt
git add file.txt nested/other.txt nested/deeper/more.txt new.txt
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
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
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
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
REVIEW_MODE_FORCE_REST_COMMENTS=1 \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/rest_fallback_fixture.lua"
