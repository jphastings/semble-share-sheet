---
# SEMBLE-y0a8
title: 'M5: Best-effort preview blocks the share sheet'
status: completed
type: bug
priority: normal
created_at: 2026-09-21T13:06:01Z
updated_at: 2026-09-21T15:28:24Z
parent: SEMBLE-m5pi
---

phase = .ready waits on the preview task, which uses URLSession.shared's 60s timeout. A slow api.semble.so (or a tarpit page behind it) holds the sheet on loading though collections are ready.

- [ ] Sheet becomes ready as soon as collections load; preview fills in when it arrives
- [ ] Metadata request has a short timeout
- [x] Behavioural test: slow preview does not delay ready

## Summary of Changes

`ShareSheetModel.load()` no longer awaits the preview: it sets `.ready` as soon as collections resolve and fills `preview` from a background task whenever it arrives. `HTTPRequest` gained an optional `timeout` applied by `URLSessionHTTPClient`; `URLMetadataClient` uses 5s.

Not verified: tests cannot be compiled or run on this machine (no Xcode).
