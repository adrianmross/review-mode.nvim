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
for ui in lua/review_mode/panel.lua lua/review_mode/picker.lua lua/review_mode/integrations/nvim_tree.lua lua/review_mode/diagnostics.lua lua/review_mode/review_buffer.lua lua/review_mode/local_buffer.lua; do
  # Lua accepts require("x"), require 'x', and require( "x" ) alike, so match the
  # call loosely rather than one spelling of it.
  if grep -nE "require[[:space:]]*\(?[[:space:]]*['\"]review_mode\.(state|github|viewed|comments|diff|init)['\"]" "$ui"; then
    echo "$ui reaches past review_mode.api (see the rule in lua/review_mode/api.lua)" >&2
    exit 1
  fi
done

stylua --check lua plugin scripts/*.lua
git diff --check
bash scripts/release-check.sh

tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-mode-nvim-test.XXXXXX")"
mkdir -p "$tmp/bin" "$tmp/repo" "$tmp/cache" "$tmp/state"

cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

# startup budget fixture: a slow network, so cache-first rendering can be told
# apart from waiting on gh
if [[ -n "${REVIEW_MODE_GH_DELAY:-}" ]]; then
  sleep "$REVIEW_MODE_GH_DELAY"
fi

case "$1 $2" in
  "pr view")
    args="$*"
    # local-fallback fixture: the two ways `gh pr view` exits 1. Real gh writes
    # both to stderr, and only the wording tells them apart.
    if [[ "${REVIEW_MODE_FIXTURE:-}" == "no_pr" ]]; then
      echo 'no pull requests found for branch "feature"' >&2
      exit 1
    elif [[ "${REVIEW_MODE_FIXTURE:-}" == "gh_auth_fail" ]]; then
      echo 'HTTP 401: Bad credentials (https://api.github.com/graphql)' >&2
      exit 1
    elif [[ "$args" == *"--json url"* && "$args" == *"-q .url"* ]]; then
      printf 'https://github.com/owner/repo/pull/123\n'
    elif [[ "$args" == *"title,state,isDraft,mergeable,reviewDecision,headRefName,baseRefName,url"* ]]; then
      printf '{"title":"Improve review tools","state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"REVIEW_REQUIRED","headRefName":"feature","baseRefName":"main","url":"https://github.com/owner/repo/pull/123"}\n'
    elif [[ "$args" == *"number,headRefOid,baseRefName,url"* ]]; then
      printf '{"number":123,"headRefOid":"abc123","baseRefName":"main","url":"https://github.com/owner/repo/pull/123"}\n'
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
  "api repos/owner/repo/pulls/123/comments/1/replies"|"api repos/owner/repo/pulls/123/comments/2/replies")
    args="$*"
    if [[ "$args" == *"--method POST"* ]]; then
      # optimistic posting: slow the answer down, or fail it
      if [[ -n "${REVIEW_MODE_POST_DELAY:-}" ]]; then
        sleep "$REVIEW_MODE_POST_DELAY"
      fi
      if [[ "${REVIEW_MODE_FAIL_POST:-}" == "1" ]]; then
        echo "forced post failure" >&2
        exit 1
      fi
      printf '{"id":100,"path":"file.txt","line":2,"body":"replied"}\n'
    else
      echo "unexpected gh replies args: $*" >&2
      exit 1
    fi
    ;;
  # edit and delete: PATCH answers the updated comment, DELETE answers 204 with
  # an empty body, as GitHub does
  "api --method")
    if [[ -n "${REVIEW_MODE_GH_LOG:-}" ]]; then
      printf '%s\n' "$*" >> "$REVIEW_MODE_GH_LOG"
    fi
    if [[ "$3 $4" == "PATCH repos/owner/repo/pulls/comments/11" ]]; then
      printf '{"id":11,"path":"file.txt","line":2,"body":"edited"}\n'
    elif [[ "$3 $4" != "DELETE repos/owner/repo/pulls/comments/11" ]]; then
      echo "unexpected gh --method args: $*" >&2
      exit 1
    fi
    ;;
  "api repos/owner/repo/pulls/123/comments")
    args="$*"
    if [[ "$args" == *"--method POST"* ]]; then
      # optimistic posting: slow the answer down, or fail it
      if [[ -n "${REVIEW_MODE_POST_DELAY:-}" ]]; then
        sleep "$REVIEW_MODE_POST_DELAY"
      fi
      if [[ "${REVIEW_MODE_FAIL_POST:-}" == "1" ]]; then
        echo "forced post failure" >&2
        exit 1
      fi
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
    elif [[ "$args" == *"reviewThreads"* && "${REVIEW_MODE_FIXTURE:-}" == "reactions" ]]; then
      printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"thread_1","path":"file.txt","line":2,"originalLine":2,"startLine":null,"diffSide":"RIGHT","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"id":"comment_1","databaseId":1,"path":"file.txt","line":2,"originalLine":2,"startLine":null,"createdAt":"2024-01-02T03:04:05Z","url":"https://github.com/owner/repo/pull/123#discussion_r1","state":"SUBMITTED","authorAssociation":"OWNER","viewerDidAuthor":false,"body":"Needs review","author":{"login":"reviewer"},"reactionGroups":[{"content":"THUMBS_UP","viewerHasReacted":true,"reactors":{"totalCount":2}},{"content":"HOORAY","viewerHasReacted":false,"reactors":{"totalCount":1}}]},{"id":"comment_5","databaseId":5,"path":"file.txt","line":2,"originalLine":2,"startLine":null,"createdAt":"2024-01-03T03:04:05Z","url":"https://github.com/owner/repo/pull/123#discussion_r5","state":"SUBMITTED","authorAssociation":"MEMBER","viewerDidAuthor":true,"body":"Done","author":{"login":"maintainer"},"reactionGroups":[]}]}}]}}}}}'
    elif [[ "$args" == *"reviewThreads"* && "${REVIEW_MODE_FIXTURE:-}" == "edit_delete" ]]; then
      if [[ -n "${REVIEW_MODE_GH_LOG:-}" ]]; then
        printf 'graphql reviewThreads\n' >> "$REVIEW_MODE_GH_LOG"
      fi
      printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"thread_ed","path":"file.txt","line":2,"originalLine":2,"startLine":null,"diffSide":"RIGHT","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"id":"comment_10","databaseId":10,"path":"file.txt","line":2,"originalLine":2,"startLine":null,"createdAt":"2024-01-02T03:04:05Z","url":"https://github.com/owner/repo/pull/123#discussion_r10","state":"SUBMITTED","authorAssociation":"MEMBER","viewerDidAuthor":false,"body":"Please rename this","author":{"login":"alice"},"reactionGroups":[]},{"id":"comment_11","databaseId":11,"path":"file.txt","line":2,"originalLine":2,"startLine":null,"createdAt":"2024-01-03T03:04:05Z","url":"https://github.com/owner/repo/pull/123#discussion_r11","state":"SUBMITTED","authorAssociation":"OWNER","viewerDidAuthor":true,"body":"Renamed in the next push\nsecond line","author":{"login":"adrian"},"reactionGroups":[]}]}}]}}}}}'
    elif [[ "$args" == *"reviewThreads"* && "${REVIEW_MODE_FIXTURE:-}" == "suggestions" ]]; then
      # Several suggestions in one file, at different lines and of different
      # lengths, so accept-all has something to get the ordering wrong on.
      printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"thread_s1","path":"file.txt","line":2,"originalLine":2,"startLine":null,"diffSide":"RIGHT","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"id":"comment_s1","databaseId":21,"path":"file.txt","line":2,"originalLine":2,"startLine":null,"createdAt":"2024-01-02T03:04:05Z","url":"https://github.com/owner/repo/pull/123#discussion_r21","state":"SUBMITTED","authorAssociation":"OWNER","viewerDidAuthor":false,"body":"Two needs more\n\n```suggestion\ntwo improved\ntwo extra\n```","author":{"login":"reviewer"},"reactionGroups":[]}]}},{"id":"thread_s2","path":"file.txt","line":4,"originalLine":4,"startLine":null,"diffSide":"RIGHT","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"id":"comment_s2","databaseId":22,"path":"file.txt","line":4,"originalLine":4,"startLine":null,"createdAt":"2024-01-02T03:04:05Z","url":"https://github.com/owner/repo/pull/123#discussion_r22","state":"SUBMITTED","authorAssociation":"OWNER","viewerDidAuthor":false,"body":"```suggestion\nbase improved\n```","author":{"login":"reviewer"},"reactionGroups":[]}]}},{"id":"thread_s3","path":"file.txt","line":6,"originalLine":6,"startLine":null,"diffSide":"RIGHT","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"id":"comment_s3","databaseId":23,"path":"file.txt","line":6,"originalLine":6,"startLine":null,"createdAt":"2024-01-02T03:04:05Z","url":"https://github.com/owner/repo/pull/123#discussion_r23","state":"SUBMITTED","authorAssociation":"OWNER","viewerDidAuthor":false,"body":"No suggestion in this one","author":{"login":"reviewer"},"reactionGroups":[]}]}},{"id":"thread_s4","path":"file.txt","line":10,"originalLine":10,"startLine":null,"diffSide":"RIGHT","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"id":"comment_s4","databaseId":24,"path":"file.txt","line":10,"originalLine":10,"startLine":null,"createdAt":"2024-01-02T03:04:05Z","url":"https://github.com/owner/repo/pull/123#discussion_r24","state":"SUBMITTED","authorAssociation":"OWNER","viewerDidAuthor":false,"body":"```suggestion\ntail improved\n```","author":{"login":"reviewer"},"reactionGroups":[]}]}}]}}}}}'
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
    elif [[ "$args" == *"addReaction"* || "$args" == *"removeReaction"* ]]; then
      printf '%s\n' "$*" >> "${REVIEW_MODE_GH_LOG:-/dev/null}"
      printf '{"data":{"reaction":{"reaction":{"content":"THUMBS_UP"}}}}\n'
    else
      echo "unexpected gh graphql args: $*" >&2
      exit 1
    fi
    ;;
  # CI annotations: check runs on the PR head, then each annotated run's
  # annotations. Real gh applies the --jq filter (one @json row per line); the
  # mock prints the rows that filter would. Only the ci fixture has any.
  "api --paginate")
    if [[ "${REVIEW_MODE_FIXTURE:-}" != "ci" ]]; then
      exit 0
    fi
    printf 'paginate %s\n' "$3" >> "${REVIEW_MODE_GH_LOG:-/dev/null}"
    case "$3" in
      "repos/owner/repo/commits/abc123/check-runs?per_page=100")
        if [[ "${REVIEW_MODE_FAIL_CI:-}" == "1" ]]; then
          echo "forced check-runs failure" >&2
          exit 1
        fi
        printf '%s\n' '["7","lint"]' '["8","test"]'
        ;;
      "repos/owner/repo/check-runs/7/annotations?per_page=100")
        printf '%s\n' '["file.txt",2,2,"failure","Unused variable","x is never used"]' '["file.txt",4,5,"warning",null,"line too long"]'
        ;;
      "repos/owner/repo/check-runs/8/annotations?per_page=100")
        printf '%s\n' '["nested/other.txt",2,2,"notice","","flaky"]'
        ;;
      *)
        echo "unexpected gh paginate args: $*" >&2
        exit 1
        ;;
    esac
    ;;
  "api repos/owner/repo/pulls/comments/1/reactions")
    printf '%s\n' "$*" >> "${REVIEW_MODE_GH_LOG:-/dev/null}"
    printf '{"id":7,"content":"+1"}\n'
    ;;
  "api repos/owner/repo/pulls/123/reviews")
    # review submission: keep the --input payload where the fixture can read it
    args=("$@")
    input=""
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [[ "${args[$i]}" == "--input" ]]; then
        input="${args[$((i + 1))]}"
      fi
    done
    if [[ "$*" != *"--method POST"* || -z "$input" ]]; then
      echo "unexpected gh reviews args: $*" >&2
      exit 1
    fi
    if [[ "${REVIEW_MODE_FAIL_REVIEW:-}" == "1" ]]; then
      echo "forced review submission failure" >&2
      exit 1
    fi
    if [[ -n "${REVIEW_MODE_REVIEW_CAPTURE:-}" ]]; then
      cp "$input" "$REVIEW_MODE_REVIEW_CAPTURE"
    fi
    printf '{"id":500,"state":"COMMENTED"}\n'
    ;;
  # Conditional comment fetch. "--include" is passed immediately after "api", so
  # this branch owns those calls without touching the plain ones above. Real gh
  # prints the status line and headers ahead of the body, and answers a matched
  # If-None-Match with 304 and exit code 1 (verified against gh 2.72.0).
  "api --include")
    endpoint=""
    inm=""
    for arg in "$@"; do
      case "$arg" in
        repos/*) endpoint="$arg" ;;
        "If-None-Match: "*) inm="${arg#If-None-Match: }" ;;
      esac
    done
    # per page, as GitHub's are: the page number is part of the ETag
    etag="\"etag-${REVIEW_MODE_ETAG_GENERATION:-1}-${endpoint##*page=}\""
    if [[ -n "${REVIEW_MODE_GH_LOG:-}" ]]; then
      printf 'include %s if-none-match=%s\n' "$endpoint" "${inm:-none}" >> "$REVIEW_MODE_GH_LOG"
    fi
    if [[ "$inm" == "$etag" ]]; then
      printf 'HTTP/2.0 304 Not Modified\nEtag: %s\r\n\r\n' "$etag"
      exit 1
    fi
    printf 'HTTP/2.0 200 OK\nEtag: %s\r\nContent-Type: application/json; charset=utf-8\r\n\r\n' "$etag"
    # reuse the payload the plain branch already answers with
    "$0" api "$endpoint"
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
# The fixture repo is a throwaway that checks out a branch and commits. Do not
# inherit the developer's global hooks (core.hooksPath): a post-checkout hook
# that keeps root checkouts on the default branch will revert this repo off its
# feature branch, and a commit-msg hook will reject the fixture's commits.
mkdir -p "$tmp/nohooks"
git config core.hooksPath "$tmp/nohooks"
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

# :ReviewModeCheckout: review the PR in a detached worktree, not this checkout.
# No GH_REVIEW_* here: the session context must come from the checkout itself.
PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/checkout-cache" \
XDG_STATE_HOME="$tmp/checkout-state" \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/no_checkout_fixture.lua"

PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/async-preview-cache" \
XDG_STATE_HOME="$tmp/async-preview-state" \
GH_REVIEW_REPO=owner/repo \
GH_REVIEW_PR=123 \
GH_REVIEW_BASE=main \
GH_REVIEW_HEAD=abc123 \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/async_preview_fixture.lua"

# Review threads as diagnostics and quickfix.
PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/diagnostics-cache" \
XDG_STATE_HOME="$tmp/diagnostics-state" \
GH_REVIEW_REPO=owner/repo \
GH_REVIEW_PR=123 \
GH_REVIEW_BASE=main \
GH_REVIEW_HEAD=abc123 \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/diagnostics_fixture.lua"

PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/reactions-cache" \
XDG_STATE_HOME="$tmp/reactions-state" \
GH_REVIEW_REPO=owner/repo \
GH_REVIEW_PR=123 \
GH_REVIEW_BASE=main \
GH_REVIEW_HEAD=abc123 \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
REVIEW_MODE_FIXTURE=reactions \
REVIEW_MODE_GH_LOG="$tmp/reactions-gh.log" \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/reactions_fixture.lua"

PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/edit-delete-cache" \
XDG_STATE_HOME="$tmp/edit-delete-state" \
GH_REVIEW_REPO=owner/repo \
GH_REVIEW_PR=123 \
GH_REVIEW_BASE=main \
GH_REVIEW_HEAD=abc123 \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
REVIEW_MODE_FIXTURE=edit_delete \
REVIEW_MODE_GH_LOG="$tmp/edit-delete-gh.log" \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/comment_edit_delete_fixture.lua"

# The resolve/unresolve confirmation flash.
PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/resolve-feedback-cache" \
XDG_STATE_HOME="$tmp/resolve-feedback-state" \
GH_REVIEW_REPO=owner/repo \
GH_REVIEW_PR=123 \
GH_REVIEW_BASE=main \
GH_REVIEW_HEAD=abc123 \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/resolve_feedback_fixture.lua"

PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/review-cache" \
XDG_STATE_HOME="$tmp/review-state" \
GH_REVIEW_REPO=owner/repo \
GH_REVIEW_PR=123 \
GH_REVIEW_BASE=main \
GH_REVIEW_HEAD=abc123 \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
REVIEW_MODE_REVIEW_CAPTURE="$tmp/review-capture.json" \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/review_submit_fixture.lua"

# CI check-run annotations as diagnostics, in their own namespace.
PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/ci-cache" \
XDG_STATE_HOME="$tmp/ci-state" \
GH_REVIEW_REPO=owner/repo \
GH_REVIEW_PR=123 \
GH_REVIEW_BASE=main \
GH_REVIEW_HEAD=abc123 \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
REVIEW_MODE_FIXTURE=ci \
REVIEW_MODE_GH_LOG="$tmp/ci-gh.log" \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/ci_fixture.lua"

# GitLab: a fake glab answers for the merge request, and the fixture points the
# repo's origin at gitlab.com so the provider is auto-detected.
cat > "$tmp/bin/glab" <<'GLAB'
#!/usr/bin/env bash
set -euo pipefail

printf 'ARGS %s\n' "$*" >> "$GLAB_LOG"
args="$*"
case "$args" in
  "mr view --output json"|"mr view 7 --repo group/project --output json")
    printf '%s\n' '{"iid":7,"project_id":42,"target_branch":"main","source_branch":"feature","sha":"headsha","web_url":"https://gitlab.com/group/project/-/merge_requests/7","references":{"full":"group/project!7"},"diff_refs":{"base_sha":"basesha","start_sha":"startsha","head_sha":"headsha"}}'
    ;;
  "api --paginate projects/group%2Fproject/merge_requests/7/discussions?per_page=100")
    printf '%s\n' '[{"id":"disc1","individual_note":false,"notes":[{"id":11,"type":"DiffNote","body":"Needs review","author":{"username":"reviewer"},"created_at":"2024-01-02T03:04:05Z","system":false,"resolvable":true,"resolved":false,"position":{"base_sha":"basesha","start_sha":"startsha","head_sha":"headsha","old_path":"file.txt","new_path":"file.txt","position_type":"text","old_line":null,"new_line":2}},{"id":12,"type":"DiffNote","body":"Agreed","author":{"username":"maintainer"},"created_at":"2024-01-03T03:04:05Z","system":false,"resolvable":true,"resolved":false,"position":{"old_path":"file.txt","new_path":"file.txt","position_type":"text","old_line":null,"new_line":2}}]},{"id":"disc2","individual_note":false,"notes":[{"id":21,"type":"DiffNote","body":"Check final line","author":{"username":"reviewer"},"created_at":"2024-01-02T03:04:05Z","system":false,"resolvable":true,"resolved":true,"position":{"old_path":"file.txt","new_path":"file.txt","position_type":"text","old_line":3,"new_line":4}}]},{"id":"disc3","individual_note":true,"notes":[{"id":31,"type":null,"body":"Overall looks good","author":{"username":"reviewer"},"created_at":"2024-01-02T03:04:05Z","system":false,"resolvable":false}]}]'
    ;;
  "api --method POST projects/group%2Fproject/merge_requests/7/discussions --input "*)
    printf 'INPUT %s\n' "$(cat "${!#}")" >> "$GLAB_LOG"
    printf '{"id":"disc_new"}\n'
    ;;
  "api --method POST projects/group%2Fproject/merge_requests/7/discussions/disc1/notes --raw-field body="*)
    printf '{"id":13}\n'
    ;;
  "api --method PUT projects/group%2Fproject/merge_requests/7/discussions/disc1 --field resolved="*)
    printf '{"id":"disc1"}\n'
    ;;
  *)
    echo "unexpected glab args: $*" >&2
    exit 1
    ;;
esac
GLAB
chmod +x "$tmp/bin/glab"

PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/gitlab-cache" \
XDG_STATE_HOME="$tmp/gitlab-state" \
GLAB_LOG="$tmp/glab.log" \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/gitlab_fixture.lua"

# Local reviews: two refs, no PR, no network, comments on disk. Deliberately no
# gh mock on PATH for this run -- the fixture asserts nothing shells out to gh.
XDG_CACHE_HOME="$tmp/local-cache" \
XDG_STATE_HOME="$tmp/local-state" \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/local_review_fixture.lua"

# Metadata caching and per-page ETag revalidation of the REST comment fetch.
PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/api-cache-cache" \
XDG_STATE_HOME="$tmp/api-cache-state" \
GH_REVIEW_REPO=owner/repo \
GH_REVIEW_PR=123 \
GH_REVIEW_BASE=main \
GH_REVIEW_HEAD=abc123 \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
REVIEW_MODE_FORCE_REST_COMMENTS=1 \
REVIEW_MODE_GH_LOG="$tmp/api-cache-gh.log" \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/api_cache_fixture.lua"

# Suggestion preview, trial apply and accept-all. Its own mock branch: the
# default one carries a single suggestion, and accept-all ordering needs
# several in one file.
PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/suggestion-cache" \
XDG_STATE_HOME="$tmp/suggestion-state" \
GH_REVIEW_REPO=owner/repo \
GH_REVIEW_PR=123 \
GH_REVIEW_BASE=main \
GH_REVIEW_HEAD=abc123 \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
REVIEW_MODE_FIXTURE=suggestions \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/suggestion_fixture.lua"

# :ReviewMode on a branch with no PR reviews it locally; any other failure
# still errors. No GH_REVIEW_* here: the fallback is about discovery.
PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/fallback-cache" \
XDG_STATE_HOME="$tmp/fallback-state" \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/local_fallback_fixture.lua"

# Defaults: no end-of-line text, no <Tab>/<S-Tab> mode keys, comments draft in the panel.
PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/ux-cache" \
XDG_STATE_HOME="$tmp/ux-state" \
GH_REVIEW_REPO=owner/repo \
GH_REVIEW_PR=123 \
GH_REVIEW_BASE=main \
GH_REVIEW_HEAD=abc123 \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/ux_defaults_fixture.lua"

# Your edits, as suggestions: found against HEAD, checked against the PR diff,
# posted or queued, then undone.
PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/edits-cache" \
XDG_STATE_HOME="$tmp/edits-state" \
GH_REVIEW_REPO=owner/repo \
GH_REVIEW_PR=123 \
GH_REVIEW_BASE=main \
GH_REVIEW_HEAD=abc123 \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/edit_suggestion_fixture.lua"

# Time to first comment sign on a warm cache, with every gh call slowed by the
# delay: the sign must come from the comment cache, not wait on the network. The
# budget sits far above the measured ~20 ms and far below the delay, so CI noise
# cannot flip it but waiting on gh always does. Override with
# REVIEW_MODE_STARTUP_BUDGET_MS. Run twice: plain discovery (gh names the PR)
# and GH_REVIEW_* (the PR is known up front).
PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/startup-cache" \
XDG_STATE_HOME="$tmp/startup-state" \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
REVIEW_MODE_STARTUP_GH_DELAY=3 \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/startup_budget_fixture.lua"

PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/startup-env-cache" \
XDG_STATE_HOME="$tmp/startup-env-state" \
GH_REVIEW_REPO=owner/repo \
GH_REVIEW_PR=123 \
GH_REVIEW_BASE=main \
GH_REVIEW_HEAD=abc123 \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
REVIEW_MODE_STARTUP_GH_DELAY=3 \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/startup_budget_fixture.lua"

# Optimistic posting: comments and replies show at once, marked sending, and
# settle to GitHub's answer or roll back. The fixture drives the mock's delay
# and failure through its own env.
PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/optimistic-cache" \
XDG_STATE_HOME="$tmp/optimistic-state" \
GH_REVIEW_REPO=owner/repo \
GH_REVIEW_PR=123 \
GH_REVIEW_BASE=main \
GH_REVIEW_HEAD=abc123 \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/optimistic_comments_fixture.lua"

# Hide whitespace: its own repo with a reindent-only file.
PATH="$tmp/bin:$PATH" \
XDG_CACHE_HOME="$tmp/whitespace-cache" \
XDG_STATE_HOME="$tmp/whitespace-state" \
GH_REVIEW_REPO=owner/repo \
GH_REVIEW_PR=123 \
GH_REVIEW_BASE=main \
GH_REVIEW_HEAD=abc123 \
REVIEW_MODE_PLUGIN_ROOT="$repo_root" \
nvim --headless -u NONE -i NONE \
  -c "set noswapfile" \
  -l "$repo_root/scripts/whitespace_fixture.lua"
