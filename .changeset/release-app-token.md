---
release: patch
---

Release automation: release-please now opens its PRs with a GitHub App token
when `RELEASE_APP_ID` and `RELEASE_APP_PRIVATE_KEY` are set, so those PRs run
CI and can satisfy branch protection. Without the secrets the previous token
chain still applies.
