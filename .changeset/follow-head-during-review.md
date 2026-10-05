---
release: minor
---

Follow HEAD during a review: a commit made while reviewing rebuilds the changed
files and hunks and re-fetches the PR head SHA, so new comments anchor to a
commit GitHub knows about. Viewed state and loaded comments are kept. Set
`follow_head = false` to require `:ReviewModeRefresh` instead.
