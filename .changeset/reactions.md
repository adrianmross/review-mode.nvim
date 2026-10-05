---
release: minor
---

Add and remove reactions on review comments: `+` in the thread panel,
`:ReviewModeReact [content]`, and `api.react({ comment = ..., content = ... })`
toggle any of GitHub's eight reactions, with your own reactions highlighted.
Comments loaded through the REST fallback can gain a reaction but not lose one.
