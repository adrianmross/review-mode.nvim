# Changelog

## Unreleased

### Changed

- Start changed-file loading immediately when launchers provide
  `GH_REVIEW_BASE`, avoiding the `gh pr view` metadata round trip on the startup
  critical path.
- Prefetch hunk locations for the active file first, then warm nearby files in
  bounded batches.
- Add a delayed background hunk scan for PRs under the configured size limit, so
  idle review time fills the hunk cache without blocking startup.

### Benchmarks

- Against `v0.2.0` on a generated fixture with 1,000 changed files and 80 lines
  per file, `PrReviewStart` returned in 2-3 ms, down from about 11 ms, and the
  changed-file map was ready in 17-28 ms, down from about 40 ms.
- On the same 1,000-file fixture, immediate middle-file hunk navigation improved
  from about 43 ms to about 21 ms. With a 50 ms pause after opening the file,
  navigation dropped to about 1.4 ms.
- Against `v0.2.0` on a generated fixture with 3,000 changed files and 80 lines
  per file, `PrReviewStart` returned in about 2 ms, down from 11-38 ms, and the
  changed-file map was ready in 21-23 ms, down from 47-84 ms.
- On the same 3,000-file fixture, immediate middle-file hunk navigation stayed
  around 21 ms, while a 50 ms pause after opening the file reduced navigation to
  about 2.6 ms.

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
