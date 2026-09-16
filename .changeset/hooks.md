---
release: minor
---

Add a `hooks` config table. Observers (`on_start`, `on_enter`, `on_leave`,
`on_stop`, `on_comments_loaded`, `on_viewed_changed`, `on_panel_open`,
`on_panel_close`, `on_comment_posted`, `on_thread_resolved`) are told what
happened and each also fires the matching `User ReviewMode*` autocommand.
Overrides are asked how something should be done and their return value replaces
the built-in behavior: `open_panel_window` decides which window the thread panel
uses, so a float, a tab, or an existing split all work. A hook that errors is
reported once and then ignored.

Internally this is also what lets the feature modules announce changes instead
of calling back into `init.lua`.
