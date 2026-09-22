---
# SEMBLE-g4sq
title: Design the pending-save state and the app's pending/failed list
status: draft
type: feature
created_at: 2026-09-22T04:17:28Z
updated_at: 2026-09-22T04:17:28Z
blocked_by:
    - SEMBLE-16dh
---

Offline saves (SEMBLE-16dh) shipped with a placeholder `.queued` screen (muted `icloud.and.arrow.up`, "Saved — will add when you're online"). Shape the real, ideally wordless, treatment with JP; the candidate sketches and open questions are in SEMBLE-16dh.

The app should also show queued saves clearing as they sync, and the saves `SaveQueue` sets aside as `.failed` after a permanent error. Those are currently invisible and never retried, so this is the only place they could surface.

Also decide: sign-out with pending saves (warn, or keep them for the same DID as today), and whether a failure deserves a local notification.
