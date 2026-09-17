---
release: patch
---

Tidy up after the parallel feature work: the thread panel's key hint now lists
`e`, `D`, `+` and `S` (each was added by a separate change that deliberately left
the shared line alone), `highlights_changed` joins the documented event list, and
the panel drops its cached comment rows when a delete starts so a key pressed
before the reload lands cannot act on a comment id GitHub has already removed.
Reacting to a pending review comment now says why it cannot work instead of
opening the reaction picker and refusing afterwards.
