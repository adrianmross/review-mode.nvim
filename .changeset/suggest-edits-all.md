---
release: patch
---

`:ReviewModeSuggestEdits!` (and "Turn all my edits into suggestions" in the actions picker) turns your edits across the whole PR into pending suggestions, not just the current file's: files with unsaved edits in a buffer, and files whose saved content differs from HEAD. One confirmation lists the count per file and how many sit outside the PR diff, which stay as edits. A file whose edits were saved is written back to match the PR once they are undone, but only when its buffer held nothing else unsaved, so unrelated work is never written for you. Edited files the PR does not change are named and left alone; without `!` the command still does only the current file.
