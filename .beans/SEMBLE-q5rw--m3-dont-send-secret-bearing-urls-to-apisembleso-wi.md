---
# SEMBLE-q5rw
title: 'M3: Don''t send secret-bearing URLs to api.semble.so without consent'
status: in-progress
type: bug
priority: high
created_at: 2026-09-21T13:06:01Z
updated_at: 2026-09-21T13:06:01Z
parent: SEMBLE-m5pi
---

load() sends the full shared URL to Semble's metadata endpoint the moment the sheet opens; Semble then crawls it, consuming one-time links and learning signed/private URLs even if the user cancels.

Decision (JP): fetch the preview automatically only when the URL has no query, fragment or userinfo. Otherwise ask for confirmation first.

- [ ] Model decides whether a URL is safe to preview automatically
- [ ] URLs with query/fragment/userinfo wait for an explicit user action before any request to api.semble.so
- [ ] Share sheet offers that action in place of the preview
- [ ] Behavioural tests for both paths
