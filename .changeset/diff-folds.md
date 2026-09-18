---
release: patch
---

Condensed and full-file diffs are now fold states in both layouts. The unified
diff holds the whole file and folds the unchanged stretches (keeping
`diff.unified_context` lines around each change), so `zR` / `zM` / `zo` / `zc`
work in it as they already did side by side. `:ReviewModeDiffFullToggle` opens
or closes those folds instead of re-rendering the diff, and `diff.full_file`
sets whether a diff opens expanded.
