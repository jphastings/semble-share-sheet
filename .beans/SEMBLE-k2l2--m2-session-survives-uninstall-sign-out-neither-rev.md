---
# SEMBLE-k2l2
title: 'M2: Session survives uninstall; sign-out neither revokes nor reports failure'
status: completed
type: bug
priority: high
created_at: 2026-09-21T13:06:01Z
updated_at: 2026-09-22T13:21:17Z
parent: SEMBLE-m5pi
---

Keychain items outlive the app, so a reinstall (or the device's next owner) inherits a working session. signOut uses try? clear() so a failed delete looks signed-out while the extension still posts, and the refresh token stays valid server-side. privacy.html claims deleting the app deletes the tokens.

- [x] clearSessionOnFreshInstall exists in SembleKit, fail-closed (flag set only once the clear succeeded), with tests. Still to wire into the app at launch.
- [ ] signOut revokes the refresh token at the authorization server's revocation_endpoint (best effort)
- [x] A failed keychain clear is surfaced and the session stays set
- [x] privacy.html states what is true

## Summary of Changes

Fresh-install detection clears an inherited session (fail-closed), sign-out revokes the refresh token (https-only, 5s timeout) and surfaces a failed Keychain clear. privacy.html now says what actually happens: sign-out revokes then deletes, deleting the app leaves Keychain items until a reinstall's first launch, and sign out first to be sure.

Noted but not changed: signing out leaves queued offline saves and the collections cache on the device (the page says so).
