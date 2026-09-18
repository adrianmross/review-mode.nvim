---
release: minor
---

Keys ship with the plugin. A review now installs `<leader>r…` keys for its
actions — `rt` thread panel, `rc` comment, `rr` reply, `rR` resolve, `rl` changed
files, `rv` viewed, `rd`/`rD`/`rf` diffs, `ra` actions, `rS` pending review, `rq`
stop — for the whole session, kept while you step out of the mode, and gives
back any mapping they shadowed when the review ends. Only `<leader>rm`, which
starts a review, still needs binding yourself. `session.keys` overrides them.

Quieter defaults: end-of-line comment summaries are off
(`comments.virtual_text = false`), and `:ReviewModeComment` drafts in the thread
panel (`comments.compose = "panel"`; `"prompt"` keeps the one-line prompt).
`<Tab>`/`<S-Tab>` and `gt` are no longer mode keys — they shadowed bufferline and
Vim's `:tabnext` for the whole review.

Fixes: `mode.keys = {}` never installed "none" as documented (an empty table
merged away into the defaults); it does now, and `false` removes a single key. A
failed `:ReviewMode` no longer leaves its keys behind, and closing a draft
returns focus to the code instead of the panel.
