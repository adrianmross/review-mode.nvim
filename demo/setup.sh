#!/usr/bin/env bash
# The repo and PR the recordings review.
#
#   demo/setup.sh          create (or reuse) adrianmross/review-mode-demo + its PR
#   demo/setup.sh reset    delete the comments a take left behind
#   demo/setup.sh path     print the local clone's path
#
# The PR is a deliberate bug worth one suggestion: adding the member discount
# dropped the quantity from the same line, so a cart of three bills as one. The
# bug is *on the changed line*, which is the only place GitHub can anchor a
# suggestion.
set -euo pipefail

repo="${REVIEW_MODE_DEMO_REPO:-adrianmross/review-mode-demo}"
dir="${REVIEW_MODE_DEMO_DIR:-$HOME/Projects/adrianmross/review-mode-demo}"

case "${1:-create}" in
path)
  printf '%s\n' "$dir"
  exit 0
  ;;
reset)
  pr=$(gh pr list --repo "$repo" --head fix-cart-total --json number -q '.[0].number')
  [ -n "$pr" ] || { echo "no demo PR open" >&2; exit 1; }
  # every review comment on the PR, including the ones a take posted
  for id in $(gh api "repos/$repo/pulls/$pr/comments" -q '.[].id'); do
    gh api --method DELETE "repos/$repo/pulls/comments/$id" >/dev/null
    echo "deleted review comment $id"
  done
  for d in "$dir" "${REVIEW_MODE_DEMO_WORKTREE:-${dir}.fix-cart-total}"; do
    [ -d "$d" ] && git -C "$d" checkout -q . 2>/dev/null || true
  done
  echo "reset: PR #$pr has no comments, working tree clean"
  exit 0
  ;;
create) ;;
*)
  echo "usage: demo/setup.sh [create|reset|path]" >&2
  exit 1
  ;;
esac

if ! gh repo view "$repo" >/dev/null 2>&1; then
  gh repo create "$repo" --public --description "The repository the review-mode.nvim recordings review." >/dev/null
  echo "created $repo"
fi

if [ ! -d "$dir/.git" ]; then
  gh repo clone "$repo" "$dir" -- -q
fi
cd "$dir"

if ! git rev-parse --verify -q main >/dev/null || [ -z "$(git log --oneline -1 2>/dev/null)" ]; then
  git checkout -q -B main
  mkdir -p src
  cat > src/cart.ts <<'TS'
export type Item = { name: string; price: number; qty: number }

/** What the customer pays for everything in the cart. */
export function total(items: Item[]): number {
  return items.reduce((sum, i) => sum + i.price * i.qty, 0)
}

export function describe(items: Item[]): string {
  const count = items.reduce((n, i) => n + i.qty, 0)
  return `${count} item(s), ${total(items).toFixed(2)}`
}
TS
  cat > README.md <<'MD'
# review-mode demo

The repository the [review-mode.nvim](https://github.com/adrianmross/review-mode.nvim)
recordings review. The open PR carries a deliberate bug.
MD
  git add -A
  git commit -qm "feat: cart totals"
  git push -q -u origin main
fi

if ! gh pr list --repo "$repo" --head fix-cart-total --json number -q '.[0].number' | grep -q '[0-9]'; then
  # The branch is built with plumbing rather than a checkout: a post-checkout
  # hook in some setups forces the root back to main, which silently landed this
  # commit on main instead of the branch.
  bug=$(mktemp)
  cat > "$bug" <<'TS'
export type Item = { name: string; price: number; qty: number }

/** What the customer pays for everything in the cart. */
export function total(items: Item[], discount = 0): number {
  return items.reduce((sum, i) => sum + i.price * (1 - discount), 0)
}

export function describe(items: Item[]): string {
  const count = items.reduce((n, i) => n + i.qty, 0)
  return `${count} item(s), ${total(items).toFixed(2)}`
}
TS
  blob=$(git hash-object -w "$bug")
  rm -f "$bug"
  index=$(mktemp -u)
  GIT_INDEX_FILE="$index" git read-tree origin/main
  GIT_INDEX_FILE="$index" git update-index --add --cacheinfo 100644,"$blob",src/cart.ts
  tree=$(GIT_INDEX_FILE="$index" git write-tree)
  rm -f "$index"
  commit=$(git commit-tree "$tree" -p origin/main -m "feat: member discount on cart totals")
  git push -q origin "$commit":refs/heads/fix-cart-total
  git fetch -q origin
  # A draft: Copilot's automatic review does not run on drafts, and a bot
  # thread on the very line the take comments on turns the demo into a reply.
  gh pr create --repo "$repo" --head fix-cart-total --base main --draft \
    --title "Member discount on cart totals" \
    --body "Applies the member discount when totalling a cart." >/dev/null
  echo "opened the demo PR"
fi

# The recording needs the PR branch checked out somewhere, and the root stays on
# main. A worktree is that somewhere: worktrunk when it is installed, plain git
# otherwise.
tree_dir="${REVIEW_MODE_DEMO_WORKTREE:-${dir}.fix-cart-total}"
if [ ! -d "$tree_dir/.git" ] && [ ! -f "$tree_dir/.git" ]; then
  if command -v wt >/dev/null 2>&1; then
    wt switch --create fix-cart-total --no-cd --no-hooks -y >/dev/null 2>&1 || true
    found=$(git worktree list --porcelain | awk '/^worktree /{w=$2} /^branch refs\/heads\/fix-cart-total$/{print w}')
    [ -n "$found" ] && tree_dir="$found"
  fi
  if [ ! -d "$tree_dir/.git" ] && [ ! -f "$tree_dir/.git" ]; then
    git worktree add -q "$tree_dir" fix-cart-total
  fi
fi
git -C "$tree_dir" fetch -q origin
git -C "$tree_dir" reset -q --hard origin/fix-cart-total

echo "demo repo ready"
echo "  repo     $dir"
echo "  record   $tree_dir   (REVIEW_MODE_DEMO_DIR for the tape)"
echo "  PR       #$(gh pr list --repo "$repo" --head fix-cart-total --json number -q '.[0].number')"
