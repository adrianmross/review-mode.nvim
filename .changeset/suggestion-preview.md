---
release: minor
---

See a suggestion before you take it: preview it in the code as virtual lines
(`p` in the panel, `:ReviewModeSuggestionPreview`) or side by side against the
file with it applied, apply it as a revertible trial that is signed in the
buffer and undone by `:ReviewModeSuggestionRevert` without disturbing edits made
around it, and accept every suggestion in a file at once with `A` or
`:ReviewModeSuggestionAcceptAll`. `:ReviewModeSuggestionList` shows the trials
that are applied but not saved.
