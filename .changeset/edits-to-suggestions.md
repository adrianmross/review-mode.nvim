---
release: patch
---

Write suggestions by editing the code. Make the change in the file, then press
`<leader>rr` on an edited line: the draft opens with the suggestion block filled
in from your edit, and posting or queueing it undoes the edit, so the change
lives on as the suggestion. `:ReviewModeSuggestEdits` (and "Turn my edits in
this file into suggestions" in the actions picker) queues every edit in the
file into the pending review. Edits outside the PR diff are refused with a
message, and trial suggestions are left out. `:ReviewModeSuggest` drafts in the
draft buffer instead of a one-line prompt.
