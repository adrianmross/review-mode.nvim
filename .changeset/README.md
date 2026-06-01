# Changesets

Add a Markdown file here for PRs that change plugin behavior, commands,
configuration, validation, or release infrastructure.

Use a short, human-readable filename:

```text
.changeset/viewed-next-navigation.md
```

Use this format:

```markdown
---
release: patch
---

Describe the user-visible change in one or two sentences.
```

Allowed `release` values are `patch`, `minor`, `major`, and `none`.
Release Please still owns the final changelog and tag. These files make release
intent visible during review and prevent non-doc behavior changes from merging
without an explicit release note.
