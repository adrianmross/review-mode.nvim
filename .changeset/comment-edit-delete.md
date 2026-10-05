---
release: minor
---

Edit and delete your own review comments. In the thread panel, `e` opens the
comment under the cursor in the draft buffer and `D` deletes it after a
confirmation; `:ReviewModeEditComment` and `:ReviewModeDeleteComment` do the
same for your most recent comment on the current line. Both are also on the
API as `api.edit_comment` and `api.delete_comment`, emit the new
`comment_edited` and `comment_deleted` hooks, and reload comments afterwards.
Comments loaded through the REST fallback carry no authorship, so they are
refused rather than guessed at.

`api.render_threads` now also returns `comment_rows`, the header row of each
comment, so a custom UI can tell which comment in a thread is under the cursor.
