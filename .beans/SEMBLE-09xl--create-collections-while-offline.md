---
# SEMBLE-09xl
title: Create collections while offline
status: completed
type: feature
created_at: 2026-09-22T04:17:28Z
updated_at: 2026-09-22T23:59:59Z
---

Offline, the share sheet disables "create collection". Queue the collection as its own write with a client-chosen TID rkey (so its AT-URI is known and selectable straight away); links to it wait until its cid is known at sync. Follow-up to SEMBLE-16dh.

## Done

A new collection is now a definition carried by the save that uses it, not an immediate network call:

- `PendingCollection` (rkey minted with `TID.next()`, name, accessType, createdAt) is a small value type whose AT-URI (`at://<did>/<collectionCollection>/<rkey>`) is knowable before it's ever written. `PendingSave` gained `newCollections: [PendingCollection]`; `ensureLinkRkeys()` mints link rkeys for those the same way it does for existing `collections`, keyed by URI either way.
- `SembleLibrary.save` writes each `newCollection` idempotently before the card, then card → note → links; links point at both existing collection refs and the refs the new collections were just given.
- `ShareSheetModel.createCollection()` is now synchronous and entirely local — no network, online or offline, one code path. It builds a `PendingCollection`, wraps it in a `CollectionSummary`, inserts and selects it, and clears the query. **Deliberate consequence: a collection created this way and then deselected, or created in a sheet that's cancelled, is never written anywhere** — nothing needed it.
- `CollectionSummary` now carries `ref: StrongRef?` and `pending: PendingCollection?` (exactly one set) instead of a bare `StrongRef`, so a pending collection is never represented by a faked `StrongRef` with an empty cid that could reach a link record.
- `SaveQueue.pendingCollections(for:)` reads queued + in-flight (not failed) items for a DID, deduped by rkey; `ShareSheetModel.load()` merges these into the picker (skipping any URI already present in the fetched list) so a second sheet offers a collection an earlier, still-queued save already created rather than risking a duplicate name. They are never written into `CollectionsCache`.
- Deleted: `Library.createCollection` / `SembleLibrary.createCollection`, `SembleLibraryError.emptyCollectionName`, and `ShareSheetModel.isCreatingCollection` / `.collectionError` / `.collectionsRefreshFailed` (creating a collection no longer depends on a successful collections refresh).
