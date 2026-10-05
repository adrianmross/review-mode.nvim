---
release: minor
---

Batch review comments into a pending review and submit it from Neovim. `<C-p>`
in the draft buffer queues a comment instead of posting it; the drafts persist
per PR in `stdpath("state")/review-mode-reviews` across restarts and render as
pending threads in the panel, the float and the signs.

`:ReviewModePending` (or `S` in the panel) opens a review buffer listing the
queued comments with an editable review body: `<CR>` jumps to a draft, `dd`
drops one, and `<C-s>` / `<C-a>` / `<C-x>` submit as COMMENT, APPROVE or
REQUEST_CHANGES, each confirmed first. `:ReviewModeSubmit` does the same without
the buffer. Drafts are cleared only once GitHub accepts the review, so a failed
submission keeps them.

New API: `api.pending()`, `api.add_pending()`, `api.remove_pending()`,
`api.discard_pending()` and `api.submit_review()`, plus the `pending_changed`
and `review_submitted` events.

Replies still post immediately -- the reviews endpoint only batches new
comments -- and a pending review started in the GitHub web UI is not merged with
local drafts.
