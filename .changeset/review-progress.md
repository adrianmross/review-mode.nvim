---
release: patch
---

The changed-files picker shows review progress. Each row has how much of the
file is reviewed (`✓` once viewed, else the share of its hunks viewed), lines
added and removed, and its comment threads with how many are resolved. The
title totals the whole review: share reviewed, files left, threads and
resolved, and `+/-`. The overall share weighs files by changed lines. The
statusline shows it too (`REVIEW owner/repo#123 62% 3/12`), and
`:ReviewModeSummary` adds the share, files left, line totals and resolved
threads. New API: `review_progress()`, `review_percent()`,
`review_fraction(path)`, `thread_counts(path)`.
