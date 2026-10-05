---
release: patch
---

Move the thread panel, the draft composer, and the file/action pickers out of
`init.lua` into `review_mode.panel` and `review_mode.picker`. Both now build on
`review_mode.api` and nothing else, joining the nvim-tree decorator, and
`validate.sh` fails if any of the three starts requiring a plugin internal
again. The panel keeps its window state locally instead of in the shared session
table.

`init.lua` is down to about 2,290 lines from roughly 4,700, with no `do ... end`
blocks left working around Lua's 200-locals-per-chunk limit (82 now).
