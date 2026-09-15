---
release: patch
---

Fix partial-line diff highlights landing on the wrong rows when a changed line
starts with `--` or `++`. Side-by-side highlights now come from `vim.diff()`
instead of temporary files and a blocking `git diff --no-index` subprocess.
