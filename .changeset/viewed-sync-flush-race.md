---
release: patch
---

Release the viewed-sync in-flight guard when a GitHub mutation fails or
succeeds, instead of clearing it on a fixed one-second timer that could let two
flushes run against the same queue.
