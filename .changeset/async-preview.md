---
release: patch
---

The viewed-file picker now loads each file's diff preview asynchronously: a
newly selected file paints a placeholder and fills in when git returns, instead
of stalling the editor on a blocking `git diff`.
