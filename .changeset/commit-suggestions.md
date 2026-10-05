---
release: patch
---

Commit trial suggestions with credit. `:ReviewModeSuggestionCommit` (and
"Commit trial suggestions, crediting reviewers" in the actions picker) commits
every live trial, and only the trial lines, as `Apply suggestions from code
review` with a `Co-authored-by:` trailer per suggester, the way GitHub's
"Commit suggestion" does. Your own edits in the same files stay out of the
commit and unstaged; staged work or edits inside a trial refuse with a message.
The confirmation can also resolve the suggestion threads, and nothing is pushed.
