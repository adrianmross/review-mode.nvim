---
release: major
---

Add `review_mode.api`, the public surface for building on the plugin: session
and file queries, comment threads, posting and resolving, navigation, the thread
renderer, and event subscriptions. The bundled nvim-tree decorations now use it
and nothing else, which is the rule that keeps the API complete — anything the
built-in UI can do, a custom one can do too.

BREAKING: the query functions are no longer on the module root. They moved to
`review_mode.api`, and `unresolved_comment_count` was renamed for consistency.

| before | after |
| --- | --- |
| `require("review_mode").is_active()` | `require("review_mode.api").is_active()` |
| `.root()` | `api.root()` |
| `.is_changed_file(path)` | `api.is_changed_file(path)` |
| `.is_changed_dir(path)` | `api.is_changed_dir(path)` |
| `.is_viewed_file(path)` | `api.is_viewed_file(path)` |
| `.is_viewed_dir(path)` | `api.is_viewed_dir(path)` |
| `.unviewed_count(path)` | `api.unviewed_count(path)` |
| `.comment_count(path)` | `api.comment_count(path)` |
| `.unresolved_comment_count(path)` | `api.unresolved_count(path)` |

`setup`, `statusline`, `mode_text` and the command-backing functions stay on the
module root, so existing keymaps and `:ReviewMode*` commands are unaffected. The
bundled `review_mode.integrations.nvim_tree` decorator needs no change on your
side.
