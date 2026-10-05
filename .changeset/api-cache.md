---
release: patch
---

Cut how often Review Mode calls the GitHub API: read-only PR metadata now goes
through gh's own response cache (`performance.gh_metadata_cache`, default
"10m"), and the REST comment list is revalidated with a per-page `If-None-Match`
instead of being re-downloaded once the comment cache TTL is up
(`comments.conditional_requests`). A 304 costs nothing against the rate limit.
`review_mode.api.request_stats()` and `:ReviewModeSummary` report how many gh
invocations a session spent and how many were answered 304.
