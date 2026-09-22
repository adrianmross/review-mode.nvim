---
release: patch
---

Cover the whole of a long review thread in the test suite. The comment anchoring
fixture now serves a thread whose first page of comments is full (100) and whose
newest replies only arrive through two follow-up `node(id:)` queries, and asserts
that `api.threads()` and the panel show the last one. It also pins the cost:
exactly one follow-up call per overflowing page and none for the threads that fit,
and a cache round-trip that still holds every reply, so a cached start cannot
serve a truncated thread.
