---
release: patch
---

Roll up per-directory viewed and unresolved-comment counts once per render
instead of walking every changed file for every node, so nvim-tree stays
responsive on large pull requests.
