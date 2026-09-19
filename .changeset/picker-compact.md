---
release: patch
---

The changed-files picker is narrower and says more. Counts are abbreviated
(`5.4k`), zeros are left blank, and each column is only as wide as the PR
needs. The preview is colored in both snacks.nvim and Telescope: a header with
the file's status, how much is reviewed, the exact counts, threads and CI
failures, then the diff. Filter with GitHub-style qualifiers in the fuzzy query
(`is:unviewed`, `has:comments`, `is:unresolved`, `is:added`, with fzf syntax
such as `!test`), and cycle the sort with `<C-s>`.
