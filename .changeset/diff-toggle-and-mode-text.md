---
release: minor
---

`:ReviewModeDiffLayoutToggle` and `:ReviewModeDiffFullToggle` now open the diff
when none is open, instead of silently changing a setting and reporting success
while nothing on screen changed. When there is no changed file to show, they say
the setting applies to the next diff rather than claiming it took effect.

Add `require("review_mode").mode_text()`, a stand-in for a statusline's mode
component: `REVIEW` while the review key layer is live and you are in normal
mode, `REVIEW INSERT` once you step into another mode, and the plain mode name
outside a review.
