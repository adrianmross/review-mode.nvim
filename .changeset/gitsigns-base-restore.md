---
release: patch
---

Reset the global Gitsigns base back to the index when review mode stops, so the
gutter stops comparing every buffer against the PR base after the review ends.
