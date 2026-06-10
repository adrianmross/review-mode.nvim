# Changelog

## [1.0.0](https://github.com/adrianmross/review-mode.nvim/compare/v0.9.0...v1.0.0) (2026-06-10)


### ⚠ BREAKING CHANGES

* rename pr-review.nvim to review-mode.nvim, including the module, commands, help tags, plugin loader, cache/state names, and documented setup.

### Features

* rename plugin to review-mode.nvim ([6910454](https://github.com/adrianmross/review-mode.nvim/commit/6910454ba33b7c5e9c0aab606b6044b738d88a61))


### Bug Fixes

* update viewed folder markers ([4e13a04](https://github.com/adrianmross/review-mode.nvim/commit/4e13a0479e817dcc77a028907a3b1278b9fe990d))
* update viewed folder markers ([e86e58e](https://github.com/adrianmross/review-mode.nvim/commit/e86e58ee01d9645bf51d1aa0a97a0e4e1f52348b))

## [0.9.0](https://github.com/adrianmross/pr-review.nvim/compare/v0.8.4...v0.9.0) (2026-06-02)


### Features

* add previewing viewed file picker ([03b66a2](https://github.com/adrianmross/pr-review.nvim/commit/03b66a2de35efb3a98ed5407299b6e86d9cd87d6))

## [0.8.4](https://github.com/adrianmross/pr-review.nvim/compare/v0.8.3...v0.8.4) (2026-06-02)


### Bug Fixes

* use diagnostic-style comment markers ([91acda4](https://github.com/adrianmross/pr-review.nvim/commit/91acda402c140501f2d88f952e92b8f919a42f28))

## [0.8.3](https://github.com/adrianmross/pr-review.nvim/compare/v0.8.2...v0.8.3) (2026-06-02)


### Bug Fixes

* show side-by-side partial highlights ([d0710af](https://github.com/adrianmross/pr-review.nvim/commit/d0710af5f1172202b9d9a434117da2d559670059))

## [0.8.2](https://github.com/adrianmross/pr-review.nvim/compare/v0.8.1...v0.8.2) (2026-06-02)


### Bug Fixes

* close stale side-by-side diffs ([55c8469](https://github.com/adrianmross/pr-review.nvim/commit/55c846920cc22bfefd245ea38cc595c71004f587))

## [0.8.1](https://github.com/adrianmross/pr-review.nvim/compare/v0.8.0...v0.8.1) (2026-06-02)


### Bug Fixes

* show added files in old view ([2f5405f](https://github.com/adrianmross/pr-review.nvim/commit/2f5405f65bd591f1ac7e602fdd82ee6bf7f798c6))

## [0.8.0](https://github.com/adrianmross/pr-review.nvim/compare/v0.7.2...v0.8.0) (2026-06-02)


### Features

* highlight partial unified diff changes ([813c053](https://github.com/adrianmross/pr-review.nvim/commit/813c053c5d5c5373546d2ab8246f15b01b39e284))

## [0.7.2](https://github.com/adrianmross/pr-review.nvim/compare/v0.7.1...v0.7.2) (2026-06-02)


### Bug Fixes

* redraw tabline after diff toggles ([b50e35f](https://github.com/adrianmross/pr-review.nvim/commit/b50e35ffd33ae6a61fd478acfb6ba37750a25ebc))

## [0.7.1](https://github.com/adrianmross/pr-review.nvim/compare/v0.7.0...v0.7.1) (2026-06-02)


### Bug Fixes

* make unified diff single-buffer ([8a475b3](https://github.com/adrianmross/pr-review.nvim/commit/8a475b370dd7a0da13617d92df2e0f5259c011b6))

## [0.7.0](https://github.com/adrianmross/pr-review.nvim/compare/v0.6.0...v0.7.0) (2026-06-01)


### Features

* add diff view toggles ([8fa1627](https://github.com/adrianmross/pr-review.nvim/commit/8fa162746bc2d254fe4fdd193e50806671f3c3b7))

## [0.6.0](https://github.com/adrianmross/pr-review.nvim/compare/v0.5.0...v0.6.0) (2026-06-01)


### Features

* remove legacy processing names ([d2db449](https://github.com/adrianmross/pr-review.nvim/commit/d2db449b3554d9716e958cc0efaf1cb0052b00e5))

## [0.5.0](https://github.com/adrianmross/pr-review.nvim/compare/v0.4.0...v0.5.0) (2026-06-01)


### Features

* improve review file markers and picker ([d14e5d3](https://github.com/adrianmross/pr-review.nvim/commit/d14e5d33528ca2d6570620c718820f3870a7ee8d))

## [0.4.0](https://github.com/adrianmross/pr-review.nvim/compare/v0.3.1...v0.4.0) (2026-06-01)


### Features

* add release automation ([62f14ee](https://github.com/adrianmross/pr-review.nvim/commit/62f14eeaa0a6d2967618a90ec38769cf9b69440e))


### Bug Fixes

* accept release please changelog headers ([ab34200](https://github.com/adrianmross/pr-review.nvim/commit/ab3420095d2eaa96496baba128e219ea5266cfcf))
* update CI cache action ([5e1cb57](https://github.com/adrianmross/pr-review.nvim/commit/5e1cb5707036edee2ae44208c2b296de64532e6c))
* use plain release tags ([55d5146](https://github.com/adrianmross/pr-review.nvim/commit/55d5146edc2eafe3e51d9341bf5618815f044956))

## v0.3.1 - 2026-06-01

### Changed

- Rename the primary review-state surface from processing/processed to
  viewed/unviewed in commands, docs, quickfix labels, notifications, and
  `nvim-tree` marker configuration.
- Prefer `viewed.enabled`, `viewed.sync`, and `nvim_tree.show_viewed` in plugin
  config while keeping the v0.3.0 `processing` and `show_processing` keys as
  compatibility aliases.
- Load GitHub review threads through GraphQL before falling back to the older PR
  comments REST endpoint, preserving thread metadata for summaries and replies.

### Added

- Add `PrReviewViewedNext` to mark the current file viewed and jump to the next
  unviewed PR file.
- Add `PrReviewSummary` for file, comment, thread, and viewed-sync counts.
- Persist and retry queued GitHub viewed-state mutations when sync is enabled
  but a mutation fails.

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
