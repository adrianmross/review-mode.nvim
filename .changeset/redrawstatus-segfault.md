---
release: patch
---

Stop segfaulting Neovim when a review session ends after the diff layout has
been toggled. `announce()` forced a synchronous `redrawstatus` while diff
windows were still being torn down, which crashes Neovim 0.11 — and because the
crash is a signal, the surrounding `pcall` could not catch it. The redraw is now
skipped when no UI is attached (where it does nothing anyway) and deferred to
the next tick otherwise.

Reproducer: open the base diff, toggle the layout twice, end the session. It
crashed in roughly 70% of headless runs before this change and 0 of 20 after.
