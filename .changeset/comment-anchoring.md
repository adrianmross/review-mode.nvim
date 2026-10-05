---
release: patch
---

Comment threads anchor where GitHub says they do: replies go to the thread's first comment (GitHub rejects replies to replies), a reload forced mid-load is no longer dropped, threads past the end of a buffer no longer break its signs, outdated and deleted-line (base side) threads are never previewed or applied as suggestions over unrelated code, accept-all skips resolved threads, `x` never sends a pending thread's id to GitHub, and resolved threads answer reply/resolve/react/edit/delete on their line. Suggestion fences follow Markdown (```` or ~~~, CRLF bodies), the REST fallback groups replies with their parent, long threads load past their first 100 comments, `:ReviewModeSuggest` always drafts in the panel, and unresolved counts count threads.
