---
release: minor
---

`:ReviewMode` on a branch with no PR now reviews it locally instead of failing,
and says so. It falls back only when `gh` answers that there is no PR — an auth,
network or rate-limit failure is still an error, since falling back then would
review a branch that may have a PR without its comments. A PR named with
`GH_REVIEW_PR` never falls back. `no_pr = "error"` restores the old behavior. The
statusline now reads `REVIEW local repo@ref` for a local review, so it is never
mistaken for a PR.
