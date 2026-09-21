---
# SEMBLE-yezf
title: 'M6: Retrying a failed save duplicates public records'
status: completed
type: bug
priority: normal
created_at: 2026-09-21T13:06:01Z
updated_at: 2026-09-21T15:28:24Z
parent: SEMBLE-m5pi
---

save() writes card, then note, then links. If a later write fails, retry starts again and writes a second card; each retry leaves another public duplicate plus an orphan.

- [ ] A retry resumes from the records already written rather than starting over
- [ ] Note length is validated before the first write
- [x] Behavioural tests: failure at note and at link, then retry, yields exactly one card

## Summary of Changes

`SembleLibrary` keeps per-URL `SaveProgress` (card ref, note ref, linked collections) and clears it on success, so a retry continues rather than writing a second public card. Note length is checked before any write. A note edited between attempts is dropped once one was written — marked with a `ponytail:` comment.

Not verified: tests cannot be compiled or run on this machine (no Xcode).
