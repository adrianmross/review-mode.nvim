---
release: patch
---

Run a viewed-sync flush that was requested while another was in flight once
that flush settles, even if it failed, instead of leaving the queued change
until some later trigger.
