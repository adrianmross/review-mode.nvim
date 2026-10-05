---
release: patch
---

Split the session state, shared helpers, and the base-version diff out of
`init.lua` into `review_mode.state`, `review_mode.util`, and `review_mode.diff`.
No behavior change; `init.lua` keeps the commands and public API and drops from
about 4,700 lines to 4,270, with top-level locals down from roughly 190 to 129
(Lua allows 200 per chunk).
