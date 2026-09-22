#!/usr/bin/env bash
# The repo and PR the recordings review.
#
#   demo/setup.sh          create (or reuse) adrianmross/review-mode-demo + its PR
#   demo/setup.sh reset    delete the comments a take left behind
#   demo/setup.sh path     print the local clone's path
#
# The PR is a deliberate bug worth one suggestion: a cart total that ignores
# quantity. Small enough to read in a GIF, wrong in a way anyone sees at once.
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
  git -C "$dir" checkout -q . 2>/dev/null || true
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
  return items.reduce((sum, i) => sum + i.price, 0)
}

export function describe(items: Item[]): string {
  return `${items.length} item(s), ${total(items).toFixed(2)}`
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
  git checkout -q -B fix-cart-total main
  # the bug under review: quantity is read, formatted, and then not charged for
  cat > src/cart.ts <<'TS'
export type Item = { name: string; price: number; qty: number }

/** What the customer pays for everything in the cart. */
export function total(items: Item[]): number {
  return items.reduce((sum, i) => sum + i.price, 0)
}

export function describe(items: Item[]): string {
  const count = items.reduce((n, i) => n + i.qty, 0)
  return `${count} item(s), ${total(items).toFixed(2)}`
}
TS
  git add -A
  git commit -qm "feat: count items by quantity"
  git push -q -u origin fix-cart-total
  gh pr create --repo "$repo" --head fix-cart-total --base main \
    --title "Count items by quantity" \
    --body "Shows the real item count in the summary line." >/dev/null
  git checkout -q fix-cart-total
  echo "opened the demo PR"
fi

echo "demo repo ready: $dir (PR $(gh pr list --repo "$repo" --head fix-cart-total --json number -q '.[0].number'))"
