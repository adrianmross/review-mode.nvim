---
release: minor
---

Quieter, panel-first defaults. End-of-line comment summaries are off
(`comments.virtual_text = false`) — the sign stays, and the thread panel is where
threads are read. `:ReviewModeComment` now drafts in the thread panel
(`comments.compose = "panel"`), opening it if needed; `"prompt"` keeps the
one-line prompt. `<Tab>`/`<S-Tab>` are no longer default mode keys, since they
shadowed buffer-cycling plugins like bufferline for the whole review. Closing a
draft also returns focus to the code instead of leaving it in the panel.
