---
release: patch
---

Fix an intermittent validation failure in the follow-HEAD check: the fixture
committed before Review Mode had recorded its reflog baseline (resolved by an
async `git rev-parse`), so on a busy machine the commit landed in the baseline
and HEAD never appeared to move. The fixture now waits for the baseline first.
