---
release: patch
---

CI failures show up as diagnostics. On a GitHub review, the annotations that
check runs attach to the PR head (lint errors, failing assertions, type errors)
are published as `vim.diagnostic` entries in their own namespace, so `]d` walks
CI failures inside the diff and they toggle apart from the review threads.
They are fetched in the background on start and on refresh, asking only the
runs that report annotations. Toggle them with `:ReviewModeCIToggle` or the
actions picker, or set `ci = { diagnostics = false }` to skip the fetch. Local and GitLab reviews are unaffected.
