---
release: patch
---

Fixtures declare how they run in a `-- fixture:` header and `scripts/validate.sh` finds them, so adding one is adding a file. Each run gets its own copy of the test repo and its own XDG dirs, runs in parallel with the others, and can be picked by name (`bash scripts/validate.sh ci author`). The gh and glab mocks live in `scripts/mock`, the gh mock now answers `unmarkFileAsViewed` as itself, and CI runs the suite on Neovim 0.11.0, stable and nightly.
