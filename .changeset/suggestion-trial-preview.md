---
release: patch
---

Previewing and applying a suggestion no longer trip over each other. Applying
takes down any open preview of that suggestion, instead of leaving it painted
over the applied lines with the suggestion drawn a second time below. Once a
suggestion is applied, `p` shows what it replaced (as deletions above it) and
the split view compares against the original. The panel's `a` toggles: on an
applied suggestion it reverts.
