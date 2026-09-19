---
release: patch
---

A plain `:ReviewMode` on a warm cache now draws the PR's cached comment signs straight away instead of waiting for `gh repo view` / `gh pr view` to name the PR (about 20 ms instead of one full `gh` round trip), then reconciles with what `gh` answers. Validation gains a startup-time budget: with a slowed mock `gh`, the first comment sign of a warm start must appear within `REVIEW_MODE_STARTUP_BUDGET_MS` (default 500 ms), and the measured time is printed.
