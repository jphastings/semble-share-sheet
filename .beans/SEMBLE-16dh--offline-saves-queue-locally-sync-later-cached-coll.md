---
# SEMBLE-16dh
title: 'Offline saves: queue locally, sync later, cached collections'
status: completed
type: feature
priority: normal
created_at: 2026-09-21T13:06:51Z
updated_at: 2026-09-22T15:00:00Z
blocked_by:
    - SEMBLE-yezf
    - SEMBLE-p3fp
---

Saving should work with no or spotty connectivity: the share sheet accepts the save, keeps it on the device, and the records reach the PDS later. Collections are cached so they can be picked without a network. The sheet flags "this will arrive later" subtly, ideally without words.

Draft: the engineering shape below is a proposal; the visual treatment needs shaping with JP before anything is built.

## What makes this non-trivial here

- **A save is three dependent writes.** Card, then note (needs the card's StrongRef), then links (need card + collection StrongRefs). A StrongRef includes a `cid` only the PDS can give us, so the queue must hold the *intent* (URL, note, chosen collections, saved-at time), not finished records. Builds directly on the resumable save from SEMBLE-yezf (M6): a queued item is a persisted `SaveRequest` plus its progress.
- **The extension dies when the sheet closes.** It cannot be relied on to sync. Something else has to drain the queue.
- **Two processes can drain at once** (app + extension, or two extension instances), which is the same hazard as SEMBLE-p3fp (M7) and would duplicate public records.
- **A crash between "PDS accepted the record" and "we wrote that down" duplicates on retry.** Records are public and permanent-ish, so at-least-once is not good enough.

## Proposed shape

- **Queue**: one JSON file per pending save in the app-group container (`group.me.byjp.SembleShare`, already entitled), written atomically, file protection `completeUntilFirstUserAuthentication`. Each item is bound to the DID that made it. Contents are private until published (URL + note), so they stay out of backups-readable plaintext as far as file protection allows; no keychain needed.
- **Idempotent writes via client-chosen record keys**: generate the TID rkeys when the item is enqueued and pass `rkey` to `createRecord`. A retry that hits "record already exists" fetches the record for its cid and carries on. This is what makes crash-mid-sync safe, and it fixes the residual M6 window too.
- **`createdAt`/`addedAt` are the moment the user tapped save**, not the sync time.
- **When to enqueue**: never pre-check reachability. Try the write with a short timeout; on a connectivity-class `URLError` enqueue and report success-pending. `NWPathMonitor` only feeds the UI hint. 4xx / invalid-record failures are not retried forever: they park the item as failed.
- **Who drains**: (1) the app on foreground, (2) the share extension on open, before/alongside its own save, (3) a `BGAppRefreshTask` registered by the app. A drain claims an item by atomic rename (`<id>.json` → `<id>.inflight`) so only one process works on it; stale claims expire.
- **Collections cache**: persist `[CollectionSummary]` in the app group per DID. The picker shows the cache immediately and revalidates in the background (also makes the online sheet faster). Refs are resolved again at sync time; a collection deleted meanwhile skips that link and keeps the card.
- **Creating a collection offline**: queue it as its own op with a client rkey (so its AT-URI is known and selectable straight away); links to it wait for its cid at sync.
- **Session trouble at sync time**: expired session keeps the queue and the app asks for sign-in; sign-out with pending items must say what will be lost (or keep them for the same DID).
- **No preview offline** (and SEMBLE-q5rw's consent rule still applies); the card is written without metadata and Semble's AppView crawls the page itself.

## Design (to shape with JP, not decided)

Wordless, per "let the app speak". Candidates to sketch:
- The saved confirmation swaps its checkmark for a pending glyph (clock / cloud-with-arrow) and a muted tint.
- Collections from cache render normally; a small cloud-slash mark in the header when the list couldn't be refreshed.
- The app's signed-in screen shows the actual queued links with the same pending glyph, clearing as they sync; failed ones are the only place words are needed.
- Wordless visually still needs a VoiceOver label.

## Open questions (carried into SEMBLE-g4sq)

- [ ] Is "saved, pending" allowed to auto-dismiss like a real save, or should it linger a beat longer?
- [ ] Sign-out with pending saves: block, warn, or keep for next sign-in as the same DID?
- [ ] Cap on queue size / age before items are surfaced as failed?
- [ ] Should pending items be editable/cancellable from the app?
- [ ] Is a local notification on sync failure wanted, or is the in-app list enough?

## Proposed breakdown (create as child beans once the shape is agreed)

- [x] Client-chosen rkeys (`TID`) + idempotent createRecord in PDSClient/SembleLibrary
- [x] Persistent save queue in the app group, with claim/expiry (`SaveQueue`)
- [x] Drain on app foreground and extension open
- [x] ~~Drain via `BGAppRefreshTask`~~ — not doing for now: JP chose foreground/open-only draining. Revisit if saves sit in the queue too long in practice.
- [x] Collections cache with stale-while-revalidate (`CollectionsCache`)
- [x] Offline collection creation → SEMBLE-09xl
- [x] Share sheet pending/offline states — **placeholder only**: `.queued` phase reuses the `.saved` layout with a muted `icloud.and.arrow.up` glyph and the words "Saved — will add when you're online". This is explicitly not the real design (see "Design" above, still to shape with JP) — no app-side pending list, no wordless treatment yet. Real design → SEMBLE-g4sq.
- [x] App pending/failed list (after design) → SEMBLE-g4sq
- [x] Privacy page: what is kept on the device and for how long

## Follow-ups

- SEMBLE-g4sq: design the pending state, plus the app's pending/failed list
- SEMBLE-09xl: create collections while offline
- SEMBLE-fp0t: fall back to the queue quickly on a flaky connection
