---
release: patch
---

The thread panel now folds a comment's `suggestion` block shut by default,
showing a one-line summary (`▸ suggestion  +3 −2  lua/foo.lua:12`) that Vim's
own fold keys open: `za` / `zo` / `zc` for one block, `zR` / `zM` for all. Any
other fenced block of four lines or more folds the same way. The panel
re-renders as the cursor moves, so what you opened is remembered per comment
and re-applied on every redraw. Set `panel.collapse_suggestions = false` to
keep drawing every block out in full.

Panel navigation got finer-grained to match: `]r` / `[r` now step message by
message across thread boundaries, while `]]` / `[[` step thread by thread,
which is what `]r` did before. In code windows `]r` / `[r` still move between
threads. A non-table `panel` value in the config now falls back to the
defaults instead of losing them, as `comments` and `files` already did.
