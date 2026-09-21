---
# SEMBLE-9yq5
title: 'M4: Thumbnail loads from any host the shared page names'
status: in-progress
type: bug
priority: normal
created_at: 2026-09-21T13:06:01Z
updated_at: 2026-09-21T15:28:24Z
parent: SEMBLE-m5pi
---

preview.imageURL is the page's og:image, accepted with any scheme and host and loaded by AsyncImage in the memory-capped extension: IP/timing leak to an attacker-chosen host, and a huge image can kill the extension for that URL.

- [ ] Only https image URLs are accepted
- [x] New RemoteThumbnailView: ephemeral session, 5s timeout, 5MB streaming cap, ImageIO thumbnail decode
- [ ] privacy.html no longer claims the app contacts no other hosts
