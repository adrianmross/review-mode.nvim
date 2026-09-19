---
release: patch
---

Approving a review now lists what it has not covered yet in the confirmation: files and hunks not viewed, CI failures on changed lines that no comment of yours covers, and unresolved threads. Only non-zero lines show, and with nothing to report the prompt is unchanged. The counts come from state already loaded and never wait on the network; comment and request-changes reviews skip the list. Turn it off with `review = { submit_check = false }`, or read the same counts from `api.review_readiness()`.
