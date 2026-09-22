---
# SEMBLE-fp0t
title: Fall back to the queue quickly on a flaky connection
status: todo
type: task
created_at: 2026-09-22T04:17:28Z
updated_at: 2026-09-22T04:17:28Z
---

A save on a connection that's up but useless can sit on "Adding…" for URLSession's 60 s default before it lands in the queue. Give the share sheet's immediate attempt a short timeout so it moves to `.queued` promptly, and leave the drains' timeouts as they are. Follow-up to SEMBLE-16dh.
