---
# SEMBLE-l893
title: Saves queued while the session is expired never post after signing back in
status: completed
type: bug
priority: high
created_at: 2026-11-16T21:46:19Z
updated_at: 2026-11-16T22:01:33Z
---

When the ATProto OAuth session has expired, the share sheet says the card is queued ("Saved — will add when you're online") but opening the app and signing back in never posts it.

- Signing in saves the session but never drains the queue, and the app only drains when `scenePhase` changes, so the save waits for the next foreground. A cold launch may not drain either.
- When the extension finds the refresh token dead it clears the Keychain, but a running app keeps its stale `AccountModel.session`: it still looks signed in, and every drain hits `invalid_grant`. `drain` swallows that.
- Refresh tokens are single-use and the bsky PDS treats a replay as theft and deletes the whole session. The app and the extension can refresh at the same moment; OAuthenticator only coalesces refreshes within one process.
- The share sheet gives no hint that the save is waiting for a sign-in, not a network.
- `SembleLibrary.save` writes to the signed-in repo without checking the `PendingSave`'s own DID.


## Done

- The app drains on launch, on every foreground and right after sign-in. Each foreground first re-reads the session from the Keychain, so one the extension found dead shows the sign-in screen. `SaveQueue.drain` now rethrows `OAuthError.sessionExpired` instead of swallowing it, and the app signs out locally when it does. Queued saves stay put and post when that account signs back in.
- `SaveQueue.attempt` reports an expired session as `.needsSignIn`. The share sheet shows a new `.awaitingSignIn` phase, which doesn't auto-dismiss: "Saved — will add once you log in" with the existing `sessionExpired` message. An expiry found while loading still lets the user save and shows the same message above the button.
- `SembleLibrary.save` refuses a `PendingSave` whose DID isn't the signed-in account's (`.differentAccount`, classified transient), so it stays queued for its own account.
- Refreshes are serialised across processes by a `flock` on a file in the app group, wrapped around OAuthenticator's `refreshProvider` (rebuilt from Bluesky's `TokenHandling`). Under the lock the client re-reads the Keychain, adopts a login another process has just rotated, and persists a new one before letting go. App drains run under a background-task assertion and the extension's under an expiring activity, so a refresh isn't suspended half-way.

Ceiling: a process killed between the server rotating the refresh token and the Keychain write still loses the session. The lock can't help there; the assertions make it rarer. The lock has no timeout; see the `ponytail:` note in `FileLock`.
