# Changelog

## v0.3.0 - 2026-06-01

### Added

- Track processed/pending state for changed PR files, persisted per PR and
  exposed through `PrReviewProcessedToggle`, `PrReviewProcessedList`, and
  `PrReviewProcessedClear`.
- Add runtime toggles for processing state and PR comments.
- Add optional processing-state sync backed by GitHub's PR file state through
  GraphQL with `processing.sync`, `PrReviewProcessedSync`, and
  `PrReviewProcessedSyncToggle`.
- Add explicit hunk navigation commands and PR comment navigation commands for
  `]h`/`[h` and `]c`/`[c` style mappings.
- Show distinct PR comment gutter signs in normal buffers and expose comment and
  processing-state markers through the `nvim-tree` decorator.

## v0.2.1 - 2026-06-01

### Changed

- Start changed-file loading immediately when launchers provide
  `GH_REVIEW_BASE`, avoiding the `gh pr view` metadata round trip on the startup
  critical path.
- Prefetch hunk locations for the active file first, then warm nearby files in
  bounded batches.
- Start focused-file hunk prefetch immediately on buffer entry, with a short
  `gitsigns.nvim` grace period when gitsigns is already attached so the two diff
  engines do not race on normal review navigation.
- Reuse cached `gitsigns.nvim` hunk locations for clean buffers when available,
  while keeping the built-in Git diff loader as the fallback and authoritative
  backend.
- Add a delayed background hunk scan for PRs under the configured size limit, so
  idle review time fills the hunk cache without blocking startup.
- Add gitsigns-enabled benchmark coverage via the `devenv` shell.

### Benchmarks

- Against `v0.2.0` on a generated fixture with 1,000 changed files and 80 lines
  per file, `PrReviewStart` returned in 1.8-2.7 ms, down from 11-14 ms, and the
  changed-file map was ready in 17-20 ms, down from 42-49 ms.
- On the same 1,000-file fixture, same-tick middle-file hunk navigation stayed
  bounded by the cold per-file Git diff at about 16-19 ms. With a 50 ms pause
  after opening the file, navigation dropped to 1.3-1.6 ms.
- Against `v0.2.0` on a generated fixture with 3,000 changed files and 80 lines
  per file, `PrReviewStart` returned in about 2.2 ms, down from about 11.5 ms,
  and the changed-file map was ready in about 21.9 ms, down from about 46.7 ms.
- On the same 3,000-file fixture, a 50 ms pause after opening the file reduced
  middle-file hunk navigation to about 2.6 ms, down from about 22.2 ms.

## v0.2.0 - 2026-06-01

### Changed

- Improve PR review startup performance by loading PR metadata and changed-file
  status asynchronously.
- Load hunk locations lazily per file instead of parsing the entire PR patch
  during `PrReviewStart`.
- Keep the built-in old-version diff backend while making base-file loading
  asynchronous and applying a temporary fast `diffopt` for the split.
- Cache changed-file indexes and `nvim-tree` decorator relpaths to reduce repeat
  work during navigation and tree rendering.

### Benchmarks

- On a generated PR fixture with 1,000 changed files and 80 lines per file,
  `PrReviewStart` returned in 11 ms, down from 311 ms on `v0.1.0`, and the
  changed-file map was ready in 42 ms, down from 311 ms.
- On a generated PR fixture with 3,000 changed files and 80 lines per file,
  `PrReviewStart` returned in 10 ms, down from 756 ms on `v0.1.0`, and the
  changed-file map was ready in 40 ms, down from 756 ms.
- First hunk navigation now pays the lazy hunk-load cost, about 15-18 ms in the
  generated benchmark, instead of front-loading all hunk parsing during
  `PrReviewStart`.

### Added

- Add a `devenv` shell with Neovim, GitHub CLI, Git, and Stylua.
- Add repeatable validation and benchmark scripts for generated PR fixtures.
