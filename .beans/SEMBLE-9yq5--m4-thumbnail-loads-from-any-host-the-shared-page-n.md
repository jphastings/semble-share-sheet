---
# SEMBLE-9yq5
title: 'M4: Thumbnail loads from any host the shared page names'
status: completed
type: bug
priority: normal
created_at: 2026-09-21T13:06:01Z
updated_at: 2026-09-22T13:21:17Z
parent: SEMBLE-m5pi
---

preview.imageURL is the page's og:image, accepted with any scheme and host and loaded by AsyncImage in the memory-capped extension: IP/timing leak to an attacker-chosen host, and a huge image can kill the extension for that URL.

- [ ] Only https image URLs are accepted
- [x] New RemoteThumbnailView: ephemeral session, 5s timeout, 5MB streaming cap, ImageIO thumbnail decode
- [x] privacy.html lists the preview image's host (and the handle and did:web fallbacks, which were missing before this finding)

## Summary of Changes

Non-https image URLs are dropped at decode; RemoteThumbnailView caps bytes while streaming and decodes a thumbnail only. privacy.html now names the preview-image host as a site the device contacts directly.
