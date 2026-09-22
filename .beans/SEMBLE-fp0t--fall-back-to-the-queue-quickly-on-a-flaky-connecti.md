---
# SEMBLE-fp0t
title: Fall back to the queue quickly on a flaky connection
status: completed
type: task
created_at: 2026-09-22T04:17:28Z
updated_at: 2026-09-22T16:00:00Z
---

A save on a connection that's up but useless can sit on "Adding…" for URLSession's 60 s default before it lands in the queue. Give the share sheet's immediate attempt a short timeout so it moves to `.queued` promptly, and leave the drains' timeouts as they are. Follow-up to SEMBLE-16dh.

## Done

The share extension's PDS client uses a 10 s request (idle) timeout; the app keeps URLSession's 60 s. It covers everything the extension does against the PDS, including its own drain of the queue: the extension is short-lived, so giving up early there costs nothing. The ceiling is per request, not per save; see the `ponytail:` note in `ShareViewController`.
