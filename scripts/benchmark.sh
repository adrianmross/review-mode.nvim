#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

files="${PR_REVIEW_BENCH_FILES:-1000}"
lines="${PR_REVIEW_BENCH_LINES:-80}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/pr-review-bench.XXXXXX")"
mkdir -p "$tmp/bin" "$tmp/repo" "$tmp/current-cache" "$tmp/current-state" "$tmp/baseline-cache" "$tmp/baseline-state"

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
    printf '[]\n'
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
GH
chmod +x "$tmp/bin/gh"

echo "Creating fixture: ${files} changed files, ${lines} lines each" >&2
cd "$tmp/repo"
git init -q
git config user.email test@example.com
git config user.name Test
git checkout -q -B main
mkdir -p src

for i in $(seq 1 "$files"); do
  path="$(printf 'src/file_%04d.txt' "$i")"
  for line in $(seq 1 "$lines"); do
    printf 'base file %04d line %04d\n' "$i" "$line"
  done > "$path"
done

git add src
git commit -q -m base
git checkout -q -b feature

for i in $(seq 1 "$files"); do
  path="$(printf 'src/file_%04d.txt' "$i")"
  tmpfile="$path.tmp"
  awk -v i="$i" -v mid="$((lines / 2))" '{
    if (NR == mid) {
      printf "feature file %04d line %04d\n", i, NR
    } else {
      print
    }
  }' "$path" > "$tmpfile"
  mv "$tmpfile" "$path"
done

git add src
git commit -q -m feature
git remote add origin .
git update-ref refs/remotes/origin/main refs/heads/main

target_file="$(printf 'src/file_%04d.txt' "$((files / 2))")"
baseline="$tmp/baseline-plugin"
mkdir -p "$baseline"
git -C "$repo_root" archive --format=tar HEAD | tar -xf - -C "$baseline"

run_case() {
  local label="$1"
  local plugin_root="$2"
  local cache="$3"
  local state="$4"

  PATH="$tmp/bin:$PATH" \
    XDG_CACHE_HOME="$cache" \
    XDG_STATE_HOME="$state" \
    GH_REVIEW_REPO=owner/repo \
    GH_REVIEW_PR=123 \
    PR_REVIEW_PLUGIN_ROOT="$plugin_root" \
    PR_REVIEW_BENCH_FILE="$target_file" \
    PR_REVIEW_BENCH_LABEL="$label" \
    nvim --headless -u NONE -i NONE \
      -c "set noswapfile" \
      -l "$repo_root/scripts/benchmark.lua"
}

echo "Benchmarking baseline HEAD" >&2
run_case "baseline_head" "$baseline" "$tmp/baseline-cache" "$tmp/baseline-state"

echo "Benchmarking current worktree" >&2
run_case "current_worktree" "$repo_root" "$tmp/current-cache" "$tmp/current-state"
