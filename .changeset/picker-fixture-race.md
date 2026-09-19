---
release: patch
---

Test-only: the picker fixture waits for the per-file line counts before
drawing rows, so it no longer races them on CI.
