---
release: patch
---

The changed-files picker is cleaner and colored. Its title is short again
(`Files [all] · 62% · 4 left`), leaving the full totals to the statusline and
`:ReviewModeSummary`. In snacks.nvim and Telescope the rows are colored: lines
added in green and removed in red (with thousands separators, `+5,449`), the
reviewed share in an accent (dim at 0%, green once viewed), comment threads in
a warning color while any are open and green once resolved, and the directory
dimmed beside the file name. Every color is a `ReviewModePicker*` highlight
group linked to a standard one, so it follows the colorscheme and can be
overridden.
