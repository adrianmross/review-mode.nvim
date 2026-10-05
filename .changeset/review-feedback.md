---
release: patch
---

Widen the API-boundary guard in `validate.sh` so it catches every Lua spelling
of `require` rather than only `require("x")`, and isolate the test fixtures from
the developer's global git hooks so a `post-checkout` or `commit-msg` hook cannot
break a throwaway fixture repo.

`api.reply` no longer needs `path` to find a thread: pass `comment_id`, or a
`thread_id` that is looked up across the changed files, with `path` narrowing the
search when you have it.

`review_mode.api` no longer re-exports `util` and the internal viewed module. A
passthrough blurred the boundary the API exists to draw.
