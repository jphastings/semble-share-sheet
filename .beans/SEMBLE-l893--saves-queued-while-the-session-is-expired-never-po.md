---
# SEMBLE-l893
title: Saves queued while the session is expired never post after signing back in
status: in-progress
type: bug
priority: high
created_at: 2026-11-16T21:46:19Z
updated_at: 2026-11-16T21:46:19Z
---

When the ATProto OAuth session has expired, the share sheet says the card is queued ("Saved — will add when you're online") but opening the app and signing back in never posts it.

- Signing in saves the session but never drains the queue, and the app only drains when `scenePhase` changes, so the save waits for the next foreground. A cold launch may not drain either.
- When the extension finds the refresh token dead it clears the Keychain, but a running app keeps its stale `AccountModel.session`: it still looks signed in, and every drain hits `invalid_grant`. `drain` swallows that.
- Refresh tokens are single-use and the bsky PDS treats a replay as theft and deletes the whole session. The app and the extension can refresh at the same moment; OAuthenticator only coalesces refreshes within one process.
- The share sheet gives no hint that the save is waiting for a sign-in, not a network.
- `SembleLibrary.save` writes to the signed-in repo without checking the `PendingSave`'s own DID.
