---
release: minor
---

Review GitLab merge requests. The provider is picked from the `origin` remote
(`provider = "auto"`, with `gitlab_hosts` for self-hosted instances) or handed
over with `GL_REVIEW_MR`, and `glab` then supplies MR metadata, diff
discussions as threads, new line comments, replies, and thread resolution. The
GitHub path is unchanged; viewed-state sync, reactions, edit/delete, review
submission, status and checks stay GitHub-only and say so instead of calling
`gh`.
