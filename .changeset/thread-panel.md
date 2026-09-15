---
release: minor
---

Render PR comments as threads instead of one-line summaries: author, repository
association, age, reply chain, emoji reactions, and resolved/outdated state, with
fenced code drawn as code and `suggestion` blocks drawn as the diff they would
apply. Add `:ReviewModePanel`, a cursor-following side split for those threads
with keys to reply, comment, resolve, apply a suggestion, and jump to the line.
Replies and comments are now drafted in a markdown buffer and confirmed before
they are sent, with `<C-r>` to quote lines selected in the code window and
`<C-g>` to seed a suggestion block. Add `:ReviewModeCompose` and
`:ReviewModeApplySuggestion`, the `panel` config table, and
`comments.show_resolved`.
