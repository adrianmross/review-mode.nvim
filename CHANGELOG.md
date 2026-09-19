# Changelog

## [0.13.7](https://github.com/adrianmross/review-mode.nvim/compare/v0.13.6...v0.13.7) (2026-09-19)


### Features

* **author:** resolve threads a commit fixed, walk unresolved, re-request review ([#110](https://github.com/adrianmross/review-mode.nvim/issues/110)) ([968f0d4](https://github.com/adrianmross/review-mode.nvim/commit/968f0d4c34e8e1d16794a75a551d9ffa61ddcb1c))
* **review:** list what an approval has not covered yet ([#106](https://github.com/adrianmross/review-mode.nvim/issues/106)) ([ef8fc61](https://github.com/adrianmross/review-mode.nvim/commit/ef8fc610ef60ef307fcd6f35247b733f7e4bcb8e))
* **review:** walk a PR in a reading order, definitions before uses ([#109](https://github.com/adrianmross/review-mode.nvim/issues/109)) ([183bfa9](https://github.com/adrianmross/review-mode.nvim/commit/183bfa98ac39602194bf02388a3c7dd040e18eed))
* **suggestions:** commit trial suggestions, crediting the suggesters ([#108](https://github.com/adrianmross/review-mode.nvim/issues/108)) ([8d6607a](https://github.com/adrianmross/review-mode.nvim/commit/8d6607aef6d33834b4d114d0daa0a27c35245ede))
* **suggestions:** turn your edits across the whole PR into suggestions ([#107](https://github.com/adrianmross/review-mode.nvim/issues/107)) ([ec7e857](https://github.com/adrianmross/review-mode.nvim/commit/ec7e8575aa93c44ebd101f4282f07167ca3d34f8))

## [0.13.6](https://github.com/adrianmross/review-mode.nvim/compare/v0.13.5...v0.13.6) (2026-09-19)


### Features

* **picker:** show review progress per file and for the whole review ([#103](https://github.com/adrianmross/review-mode.nvim/issues/103)) ([c31c30d](https://github.com/adrianmross/review-mode.nvim/commit/c31c30d))

### Bug Fixes

* **viewed:** run a flush requested while another is in flight ([#102](https://github.com/adrianmross/review-mode.nvim/issues/102)) ([0cb421e](https://github.com/adrianmross/review-mode.nvim/commit/0cb421ef66db4a8d5044e101209556922681dc13))

## [0.13.5](https://github.com/adrianmross/review-mode.nvim/compare/v0.13.4...v0.13.5) (2026-09-19)


### Features

* **ci:** show CI check-run annotations as diagnostics ([#99](https://github.com/adrianmross/review-mode.nvim/issues/99)) ([141e869](https://github.com/adrianmross/review-mode.nvim/commit/141e869164e4b27c4ddc7e5be3b22a5efeb6d06d))
* **diff:** hide whitespace-only changes ([#95](https://github.com/adrianmross/review-mode.nvim/issues/95)) ([f453248](https://github.com/adrianmross/review-mode.nvim/commit/f453248f55c4e1b9985671741a0430aaa8790457))
* **diff:** mark moved code and let ]c skip hunks that only move it ([#96](https://github.com/adrianmross/review-mode.nvim/issues/96)) ([cbb70ea](https://github.com/adrianmross/review-mode.nvim/commit/cbb70ea638ac01b49ba0b41c1cd3ec35c9878414))
* **inbox:** pick a PR waiting on your review and review it ([#93](https://github.com/adrianmross/review-mode.nvim/issues/93)) ([5c1f88b](https://github.com/adrianmross/review-mode.nvim/commit/5c1f88be893db6f62194d02813ef75c24d2a4079))
* **review:** list callers of changed functions the PR did not touch ([#97](https://github.com/adrianmross/review-mode.nvim/issues/97)) ([c36edf7](https://github.com/adrianmross/review-mode.nvim/commit/c36edf7688dce86799fcd3e98a699a32fbf49ca3))
* **viewed:** mark individual hunks viewed ([#98](https://github.com/adrianmross/review-mode.nvim/issues/98)) ([dbfc08b](https://github.com/adrianmross/review-mode.nvim/commit/dbfc08b9b8ff00e9d5b8dfc82e322a5b6c39df06))


### Performance Improvements

* **comments:** show comments and replies while they post ([#100](https://github.com/adrianmross/review-mode.nvim/issues/100)) ([29604ad](https://github.com/adrianmross/review-mode.nvim/commit/29604ad7d84adc5fc061cc43d621468a9a82dc8f))
* **startup:** draw cached comment signs before gh names the PR ([#94](https://github.com/adrianmross/review-mode.nvim/issues/94)) ([4b2f973](https://github.com/adrianmross/review-mode.nvim/commit/4b2f973fbd2615f1edbae594876a1737387d2da6))

## [0.13.4](https://github.com/adrianmross/review-mode.nvim/compare/v0.13.3...v0.13.4) (2026-09-18)


### Features

* **suggestions:** write a suggestion by editing the code ([#90](https://github.com/adrianmross/review-mode.nvim/issues/90)) ([2e12ad7](https://github.com/adrianmross/review-mode.nvim/commit/2e12ad788c6e260745d12157d894075b2dee9772))

## [0.13.3](https://github.com/adrianmross/review-mode.nvim/compare/v0.13.2...v0.13.3) (2026-09-18)


### Bug Fixes

* **suggestions:** keep preview and trial apply from drawing over each other ([#88](https://github.com/adrianmross/review-mode.nvim/issues/88)) ([d3bf113](https://github.com/adrianmross/review-mode.nvim/commit/d3bf113130dad7747a52651ef67265f17229bddb))

## [0.13.2](https://github.com/adrianmross/review-mode.nvim/compare/v0.13.1...v0.13.2) (2026-09-18)


### Features

* **diff:** make condensed and full file fold states in both layouts ([#86](https://github.com/adrianmross/review-mode.nvim/issues/86)) ([afa4f30](https://github.com/adrianmross/review-mode.nvim/commit/afa4f30cf7ed29dbb9c1f35ef1ec632105c5c983))

## [0.13.1](https://github.com/adrianmross/review-mode.nvim/compare/v0.13.0...v0.13.1) (2026-09-18)


### Features

* **actions:** list every action, grouped, with its key ([#83](https://github.com/adrianmross/review-mode.nvim/issues/83)) ([67414a4](https://github.com/adrianmross/review-mode.nvim/commit/67414a49ad66bf607a4ac88e880f7da0ef3b68bf))

## [0.13.0](https://github.com/adrianmross/review-mode.nvim/compare/v0.12.4...v0.13.0) (2026-09-18)


### ⚠ BREAKING CHANGES

* **keys:** default review keys are renamed; <leader>rc, ]h/[h and <Esc> are gone.

### Features

* **keys:** make r the one comment key ([#81](https://github.com/adrianmross/review-mode.nvim/issues/81)) ([3d1ee99](https://github.com/adrianmross/review-mode.nvim/commit/3d1ee9968fbfea43a1735d5ef313ca54766290d9))

## [0.12.4](https://github.com/adrianmross/review-mode.nvim/compare/v0.12.3...v0.12.4) (2026-09-18)


### Features

* **review:** panel-first defaults and keys that ship with the plugin ([#79](https://github.com/adrianmross/review-mode.nvim/issues/79)) ([ab3b8c0](https://github.com/adrianmross/review-mode.nvim/commit/ab3b8c091f2d0171a58748691542cbb92a81e8b0))

## [0.12.3](https://github.com/adrianmross/review-mode.nvim/compare/v0.12.2...v0.12.3) (2026-09-18)


### Features

* **review:** review a branch with no PR locally ([#76](https://github.com/adrianmross/review-mode.nvim/issues/76)) ([7d412ba](https://github.com/adrianmross/review-mode.nvim/commit/7d412baffb0ce51d0f1eab749bca0f903301e785))

## [0.12.2](https://github.com/adrianmross/review-mode.nvim/compare/v0.12.1...v0.12.2) (2026-09-18)


### Features

* **comments:** show when a thread's resolved state changes ([#70](https://github.com/adrianmross/review-mode.nvim/issues/70)) ([21196aa](https://github.com/adrianmross/review-mode.nvim/commit/21196aa7828ea52f14de46b5860dc74a336a94ef))
* **local:** review local diffs with on-disk comments ([#72](https://github.com/adrianmross/review-mode.nvim/issues/72)) ([d851459](https://github.com/adrianmross/review-mode.nvim/commit/d851459801b21bc8d91960fb1ff5b4c2f9b6632a))
* **suggestions:** preview, trial-apply and accept suggestions ([#74](https://github.com/adrianmross/review-mode.nvim/issues/74)) ([32930c5](https://github.com/adrianmross/review-mode.nvim/commit/32930c59bda8ed496cd82afbb6ffff09adf332c1))


### Performance Improvements

* **github:** cache the PR node id and revalidate comments with ETags ([#73](https://github.com/adrianmross/review-mode.nvim/issues/73)) ([ff8ca91](https://github.com/adrianmross/review-mode.nvim/commit/ff8ca9133106ac3af5eb27ad52302fbef1e0bae5))

## [0.12.1](https://github.com/adrianmross/review-mode.nvim/compare/v0.12.0...v0.12.1) (2026-09-17)


### Features

* **checkout:** review a PR without checking it out ([#64](https://github.com/adrianmross/review-mode.nvim/issues/64)) ([a654a24](https://github.com/adrianmross/review-mode.nvim/commit/a654a24536f50fa8aaff790b00ac39efb80c8bfd))
* **comments:** add and remove reactions ([#65](https://github.com/adrianmross/review-mode.nvim/issues/65)) ([0428afd](https://github.com/adrianmross/review-mode.nvim/commit/0428afd169f7fb314df9d5ea16fe52a6e0e2da63))
* **comments:** edit and delete your own review comments ([#61](https://github.com/adrianmross/review-mode.nvim/issues/61)) ([45bdd65](https://github.com/adrianmross/review-mode.nvim/commit/45bdd657a6c3b140496c0ca59c44c49f7af0b4d7))
* **diagnostics:** expose review threads as diagnostics and quickfix ([#63](https://github.com/adrianmross/review-mode.nvim/issues/63)) ([89683a4](https://github.com/adrianmross/review-mode.nvim/commit/89683a4a7498a0853eb53748a146d2d4ecf4423f))
* **providers:** review GitLab merge requests ([#66](https://github.com/adrianmross/review-mode.nvim/issues/66)) ([fd54c08](https://github.com/adrianmross/review-mode.nvim/commit/fd54c08d2ea55058a470455a956735f5645e5354))
* **review:** submit reviews with batched pending comments ([#62](https://github.com/adrianmross/review-mode.nvim/issues/62)) ([94649ea](https://github.com/adrianmross/review-mode.nvim/commit/94649ea3ec6868baa13232ebd83b20124f1eaa5c))


### Performance Improvements

* **picker:** load the viewed-file diff preview asynchronously ([#67](https://github.com/adrianmross/review-mode.nvim/issues/67)) ([13b9034](https://github.com/adrianmross/review-mode.nvim/commit/13b9034c6748fd1725295e4fcd676be5f42c1711)), closes [#58](https://github.com/adrianmross/review-mode.nvim/issues/58)

## [0.12.0](https://github.com/adrianmross/review-mode.nvim/compare/v0.11.0...v0.12.0) (2026-09-16)


### ⚠ BREAKING CHANGES

* **api:** the query functions moved off the module root to review_mode.api, and unresolved_comment_count is now api.unresolved_count. is_active, root, is_changed_file, is_changed_dir, is_viewed_file, is_viewed_dir, unviewed_count and comment_count are affected. setup, statusline, mode_text and the command-backing functions stay on the root, so :ReviewMode* commands and existing keymaps are unaffected.

### Features

* **api:** add a public API, hooks, and a richer comment UI ([#59](https://github.com/adrianmross/review-mode.nvim/issues/59)) ([aa35866](https://github.com/adrianmross/review-mode.nvim/commit/aa358667427f316f6093e4625f91ae295967b291))

## [0.11.0](https://github.com/adrianmross/review-mode.nvim/compare/v0.10.2...v0.11.0) (2026-09-15)


### ⚠ BREAKING CHANGES

* the "native" picker provider no longer has a diff preview, live filtering or an in-picker viewed toggle. Install snacks.nvim or Telescope for those; :ReviewModeViewedToggle still works everywhere.

### Features

* **mode:** step in and out without ending the session ([#54](https://github.com/adrianmross/review-mode.nvim/issues/54)) ([0d33012](https://github.com/adrianmross/review-mode.nvim/commit/0d3301272c5569486afdaf241dadc1ca2467e8b8))
* **review:** follow HEAD so mid-review commits join the review ([#55](https://github.com/adrianmross/review-mode.nvim/issues/55)) ([b46e28f](https://github.com/adrianmross/review-mode.nvim/commit/b46e28fde2a206e979a6de45200efae292955a40))


### Bug Fixes

* **cache:** prune stale PR comment cache entries ([#50](https://github.com/adrianmross/review-mode.nvim/issues/50)) ([ccd926c](https://github.com/adrianmross/review-mode.nvim/commit/ccd926c4866ea96b5cbb8ac0ad8bf2c8e972bd45))
* **diff:** stop reading changed lines as diff headers ([#43](https://github.com/adrianmross/review-mode.nvim/issues/43)) ([6feede9](https://github.com/adrianmross/review-mode.nvim/commit/6feede9d0d0bf1fa38bb445de39fe49b3cd26979))
* **github:** stop blocking the editor on PR writes ([#45](https://github.com/adrianmross/review-mode.nvim/issues/45)) ([0672dc7](https://github.com/adrianmross/review-mode.nvim/commit/0672dc7578aa40e7341ceca8ce174103cb181d93))
* **gitsigns:** hand the gutter base back when the session ends ([#51](https://github.com/adrianmross/review-mode.nvim/issues/51)) ([ce072d4](https://github.com/adrianmross/review-mode.nvim/commit/ce072d460ae6c1620d649fc4d3479faba54e0c05))
* **viewed:** release the sync guard on completion, not on a timer ([#44](https://github.com/adrianmross/review-mode.nvim/issues/44)) ([b8bd98f](https://github.com/adrianmross/review-mode.nvim/commit/b8bd98f9eb52e45378d772fab6b0109b6c1be329))


### Performance Improvements

* **nvim-tree:** roll up directory totals once per render ([#47](https://github.com/adrianmross/review-mode.nvim/issues/47)) ([3bb05d5](https://github.com/adrianmross/review-mode.nvim/commit/3bb05d524004007f803ce9f5de18da83cc41dff7))
* **picker:** build snacks previews per selection ([#46](https://github.com/adrianmross/review-mode.nvim/issues/46)) ([9ef4de7](https://github.com/adrianmross/review-mode.nvim/commit/9ef4de7f177d0d22fde9d0f154ba1af4ffb4900f))


### Code Refactoring

* replace the native picker with vim.ui.select ([#48](https://github.com/adrianmross/review-mode.nvim/issues/48)) ([b71d8b4](https://github.com/adrianmross/review-mode.nvim/commit/b71d8b4032e477c0c041617bd10de5c91691eff8))

## [0.10.2](https://github.com/adrianmross/review-mode.nvim/compare/v0.10.1...v0.10.2) (2026-06-11)


### Features

* add external picker providers ([#41](https://github.com/adrianmross/review-mode.nvim/issues/41)) ([8a7b304](https://github.com/adrianmross/review-mode.nvim/commit/8a7b304f49e3d663b4b5b669151039f78a7b6e73))

## [0.10.1](https://github.com/adrianmross/review-mode.nvim/compare/v0.10.0...v0.10.1) (2026-06-10)


### Features

* add ReviewMode action helpers ([#39](https://github.com/adrianmross/review-mode.nvim/issues/39)) ([e6e796b](https://github.com/adrianmross/review-mode.nvim/commit/e6e796bb1ab83f7c98164a532940f2b27910a82a))

## [0.10.0](https://github.com/adrianmross/review-mode.nvim/compare/v0.9.0...v0.10.0) (2026-06-10)


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
