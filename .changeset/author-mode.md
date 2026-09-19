---
release: patch
---

Review mode now helps the PR's author through the round after feedback. When a
commit made mid-review changes a line an unresolved thread sits on, you are
offered, in one confirmation listing them, to reply "Fixed in `<sha>`" to each
and resolve it (`author.offer_resolve`, on by default, only when you wrote the
PR). `:ReviewModeNextUnresolved` / `:ReviewModePrevUnresolved` step through the
threads still open across the PR, and `:ReviewModeRerequest` re-requests review
from everyone who has reviewed, after a confirmation naming them.
