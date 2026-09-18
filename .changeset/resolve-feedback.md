---
release: minor
---

Resolving or unresolving a review thread now briefly marks the line it sat on,
in the colour of its new state, so the change is confirmed where you made it
instead of the comment simply disappearing. It is driven by the
`thread_resolved` event, so the panel's `R`, the commands and the GitLab
provider all show it. New `comments.resolve_flash_ms` (default 1200) sets how
long it lasts; `0` turns it off.

Also fixes `:ReviewModeResolveThread` and `:ReviewModeUnresolveThread`, which
were registered as bare command callbacks and so took the command table as the
thread id instead of reading the thread on the current line.
