---
# SEMBLE-p3fp
title: 'M7: Keychain session handling loses or wipes sessions'
status: completed
type: bug
priority: normal
created_at: 2026-09-21T13:06:01Z
updated_at: 2026-09-21T17:24:38Z
parent: SEMBLE-m5pi
---

Three compounding faults: delete-then-add loses the session (and the freshly rotated refresh token) when the add fails; a process holding a stale refresh token gets invalid_grant and clears another instance's newer valid session; the item is AfterFirstUnlock without ThisDeviceOnly so the DPoP key migrates via backups.

- [ ] save updates in place, adding only when the item is absent
- [ ] Token retrieval reads the store so a stale process picks up rotated tokens
- [x] invalid_grant clears the store only if the stored refresh token is the rejected one
- [x] Item is WhenUnlockedThisDeviceOnly (existing items migrated on next save)

## Summary of Changes

`KeychainSessionStore.save` updates in place (add only on errSecItemNotFound) and the item is now `WhenUnlockedThisDeviceOnly`, keeping the DPoP key out of backups. `SessionVault` gained `retrieveLogin()` (prefers the stored login when it is readable and for the same DID) and `clearIfStillRejected()` (clears only when the store still holds the token the server rejected; adopts a newer login otherwise).

Not verified: tests cannot be compiled or run on this machine (no Xcode).
