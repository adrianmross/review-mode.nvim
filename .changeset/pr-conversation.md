---
release: patch
---

Show the PR's conversation in the thread panel: the comments on the pull
request that are not anchored to a line, and the bodies of submitted reviews
with the verdict they carried. The panel's new `c` key switches between the
threads and the conversation, `r` there drafts a new PR comment through the
usual draft buffer and confirmation, and `api.conversation()` returns the same
list for hooks and agents. On GitLab the conversation is the MR notes without a
diff position; a local review has none and fetches nothing.
