#!/usr/bin/env bash
# The static checks, then the fixtures.
#
#   bash scripts/validate.sh              every fixture
#   bash scripts/validate.sh ci author    ci_fixture and author_fixture ('suggestion*': a glob)
#   REVIEW_MODE_JOBS=1                    fixtures at a time (default: one per CPU)
#   REVIEW_MODE_VERBOSE=1                 print every fixture's output, not only a failure's
#
# Fixtures register themselves: each scripts/*_fixture.lua runs once per
# "-- fixture:" line at its top, or once with nothing set if it has none:
#
#   -- fixture: gh pr REVIEW_MODE_FIXTURE=ci REVIEW_MODE_GH_LOG={tmp}/gh.log
#
#   gh          scripts/mock (fake gh and glab) first on PATH
#   pr          GH_REVIEW_REPO=owner/repo GH_REVIEW_PR=123 GH_REVIEW_BASE=main
#               GH_REVIEW_HEAD=abc123: the PR is known up front
#   NAME=value  exported; {tmp} in the value is the run's own scratch dir
#
# Every run starts in its own copy of the template repo built below, with its
# own XDG dirs, so nothing one fixture commits, checks out or reconfigures can
# reach another; runs are free to go in parallel.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# Everything throwaway lives here: removed when the run passes, kept for a look
# when it fails.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-mode-nvim-test.XXXXXX")"
trap 'if [[ $? -eq 0 ]]; then rm -rf "$tmp"; else echo "kept $tmp" >&2; fi' EXIT

# None of the developer's setup may reach a fixture: no ~/.gitconfig (signing,
# diff prefixes, hooks, default branch) and no ~/.config/nvim or site dir on
# the runtimepath.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
export XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data"
export XDG_CACHE_HOME="$tmp/cache" XDG_STATE_HOME="$tmp/state"

# :helptags only reports a duplicate tag (E154); inside try, cquit makes it fail.
mkdir -p "$tmp/help"
cp doc/review-mode.txt "$tmp/help/review-mode.txt"
# the directory goes through an env var and fnameescape, so a temp path with
# spaces still reaches :helptags whole
REVIEW_MODE_HELP_DIR="$tmp/help" nvim --headless -u NONE -i NONE \
  -c "try | execute 'helptags' fnameescape(\$REVIEW_MODE_HELP_DIR) | catch | call writefile([v:exception], '/dev/stderr') | cquit 1 | endtry" \
  -c qa

# every command tagged in :help, every |link| resolving, every event documented
nvim --headless -u NONE -i NONE -l scripts/check-docs.lua

# The bundled UI must build on the public API, the same as anyone else's would.
# If one of these needs a plugin internal, the API is missing something: add it
# to review_mode.api rather than reaching around it.
for ui in lua/review_mode/panel.lua lua/review_mode/picker.lua lua/review_mode/integrations/nvim_tree.lua lua/review_mode/diagnostics.lua lua/review_mode/review_buffer.lua lua/review_mode/local_buffer.lua lua/review_mode/inbox.lua; do
  # Lua accepts require("x"), require 'x', and require( "x" ) alike, so match the
  # call loosely rather than one spelling of it.
  if grep -nE "require[[:space:]]*\(?[[:space:]]*['\"]review_mode\.(state|github|viewed|comments|diff|init)['\"]" "$ui"; then
    echo "$ui reaches past review_mode.api (see the rule in lua/review_mode/api.lua)" >&2
    exit 1
  fi
done

stylua --check lua plugin scripts
# whitespace errors in everything this branch changes, committed or not; with no
# origin/main to compare against (a shallow clone), only uncommitted changes
git diff --check "$(git merge-base HEAD origin/main 2>/dev/null || echo HEAD)"
bash scripts/release-check.sh

# Which fixtures run: all, or those an argument names, with or without the
# _fixture suffix; an argument may be a glob.
# scripts/fixture.lua predates the _fixture name (see legacy_header).
fixtures=()
for file in scripts/fixture.lua scripts/*_fixture.lua; do
  name="$(basename "$file" .lua)"
  if [[ $# -eq 0 ]]; then
    fixtures+=("$file")
    continue
  fi
  for pattern in "$@"; do
    # shellcheck disable=SC2053 # a pattern may be a glob: 'suggestion*'
    if [[ "$name" == $pattern || "$name" == ${pattern}_fixture ]]; then
      fixtures+=("$file")
      break
    fi
  done
done
if [[ ${#fixtures[@]} -eq 0 ]]; then
  echo "no fixture matches: $*" >&2
  exit 1
fi

# The template repo each run copies: a feature branch off main, with origin/main
# where a fetched PR base would be.
mkdir -p "$tmp/template" "$tmp/nohooks"
(
  cd "$tmp/template"
  git init -q
  # Do not inherit the developer's global hooks (core.hooksPath): a
  # post-checkout hook that keeps root checkouts on the default branch will
  # revert this repo off its feature branch, and a commit-msg hook will reject
  # the fixture's commits.
  git config core.hooksPath "$tmp/nohooks"
  git config user.email test@example.com
  git config user.name Test
  git checkout -q -B main
  printf 'one\n\nbase\nsame1\nsame2\nsame3\nsame4\nsame5\ntail\n' > file.txt
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
)

# ponytail: scripts/fixture.lua is being edited in #118, so its header lives
# here for now. Once #118 merges, add "-- fixture: gh pr" to its first line and
# delete this function.
legacy_header() {
  [[ "$1" == scripts/fixture.lua ]] && echo "gh pr"
}

# One run of one fixture: the file and which of its header lines (1-based).
# Output is buffered in the run's dir; the caller prints it on failure. A run
# fails on a nonzero exit, on a missing harness.done() sentinel (it stopped
# early, e.g. on an unstubbed prompt), or on an error Neovim only printed:
# errors in scheduled callbacks and autocmds do not change the exit code.
run_fixture() {
  local file="$1" index="$2" name dir header status=0 reason="" started=$SECONDS
  name="$(basename "$file" .lua)"
  dir="$tmp/runs/$name.$index"
  header="$(grep '^-- fixture:' "$file" | sed -n "${index}p" | sed 's/^-- fixture://')" || true
  if [[ -z "$header" ]]; then
    header="$(legacy_header "$file")" || true
  fi
  mkdir -p "$dir/cache" "$dir/state" "$dir/config" "$dir/data"
  cp -R "$tmp/template" "$dir/repo"
  # a checkout fetches from the PR's repo URL; point that URL back at this copy
  git -C "$dir/repo" config url."$dir/repo".insteadOf https://github.com/owner/repo
  (
    cd "$dir/repo"
    export XDG_CACHE_HOME="$dir/cache" XDG_STATE_HOME="$dir/state"
    export XDG_CONFIG_HOME="$dir/config" XDG_DATA_HOME="$dir/data"
    export REVIEW_MODE_PLUGIN_ROOT="$repo_root" REVIEW_MODE_DONE="$dir/done"
    local word words
    read -ra words <<<"$header"
    # guarded, not ${words[@]+...}: an empty array trips set -u on bash 3.2, and
    # the quoted expansion keeps a token with glob characters whole
    [[ ${#words[@]} -gt 0 ]] || words=("")
    for word in "${words[@]}"; do
      case "$word" in
        "") ;; # a fixture with no header words
        gh) export PATH="$repo_root/scripts/mock:$PATH" ;;
        pr) export GH_REVIEW_REPO=owner/repo GH_REVIEW_PR=123 GH_REVIEW_BASE=main GH_REVIEW_HEAD=abc123 ;;
        *=*) export "${word//\{tmp\}/$dir}" ;;
        *)
          echo "$file: unknown word in its fixture header: $word" >&2
          exit 2
          ;;
      esac
    done
    exec nvim --headless -u NONE -i NONE -c "set noswapfile" -l "$repo_root/$file"
  ) >"$dir/out" 2>"$dir/err" || status=$?
  if [[ $status -ne 0 ]]; then
    reason="exit code $status"
  elif [[ ! -f "$dir/done" ]]; then
    reason="exited before harness.done()"
  elif grep -qE "Error executing|Error detected while processing|E5108|stack traceback" "$dir/err"; then
    reason="error printed to stderr"
  fi
  if [[ -n "$reason" ]]; then
    echo "$reason" >"$dir/failed"
    echo "FAIL $name.$index: $reason ($((SECONDS - started))s)"
    return 1
  fi
  echo "ok   $name.$index ($((SECONDS - started))s)"
}
export -f run_fixture legacy_header
export tmp repo_root

runs=()
for file in "${fixtures[@]}"; do
  count="$(grep -c '^-- fixture:' "$file")" || true
  for ((index = 1; index <= (count > 0 ? count : 1); index++)); do
    runs+=("$file" "$index")
  done
done

jobs="${REVIEW_MODE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
status=0
printf '%s\n' "${runs[@]}" | xargs -n 2 -P "$jobs" bash -c 'run_fixture "$@"' _ || status=$?

# each run's own output, after the fact so parallel runs do not interleave
for dir in "$tmp"/runs/*; do
  if [[ -f "$dir/failed" || -n "${REVIEW_MODE_VERBOSE:-}" ]]; then
    echo "--- $(basename "$dir")${REVIEW_MODE_VERBOSE:+ output}"
    cat "$dir/out" "$dir/err"
    echo
  fi
done >&2
if [[ $status -ne 0 ]]; then
  echo "$(find "$tmp/runs" -name failed | wc -l | tr -d ' ') of $((${#runs[@]} / 2)) fixture runs failed" >&2
  exit 1
fi
echo "$((${#runs[@]} / 2)) fixture runs passed"
