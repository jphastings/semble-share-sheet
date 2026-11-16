---
# SEMBLE-0ekz
title: Add links to other people's open collections
status: completed
type: feature
created_at: 2026-11-16T22:19:46Z
updated_at: 2026-11-16T22:19:46Z
---

Let the share sheet add a link to other people's open collections, not just the user's own, as Semble's browser extension does in its "Open collections" tab. The picker shows two groups, "Mine" and "Shared": with an empty search, Shared lists the open collections the user has already added to (`network.cosmik.collection.listContributed`); while typing, it lists anyone's open collections matching the text (`network.cosmik.collection.search`). Both are public, unauthenticated api.semble.so endpoints.

A link to a shared collection is an ordinary `collectionLink` in the user's own repo pointing at the other person's collection, which is how Semble itself records a contributor. The strong ref needs a cid the API doesn't return, so it has to come from the owner's PDS, without ever sending the user's tokens there. Semble or an owner's PDS being down must never fail the sheet, block saving to own collections, or stop the user creating one.

Alongside: the collection list should fill the sheet's spare height rather than a fixed 220 pt, and fade its bottom row while there's more to scroll.

## Done

`SharedCollectionsClient` lists and searches through Semble's API and reads a collection's cid unauthenticated from its owner's PDS (found with `IdentityResolver`), over plain `HTTPClient`, never `PDSClient`. The cid is looked up when a shared collection is ticked; `save()` waits for any lookup still running, and one that fails unticks the collection, marks the row unavailable and stops the save so the user sees it go. Semble doesn't check the cid, so cids found are cached with the contributed list (`CollectionsCache`, a second file per DID; old cache files still decode) and those collections can be linked offline. `PendingSave` is unchanged. Search waits 300 ms after the last keystroke and cancels the previous request; until results arrive (or if Semble is down) Shared filters the contributed list locally. Name clashes for a new collection are checked against the user's own only.

The list fills the space between the search field and the note (two rows at minimum, for when the keyboard is up) and fades its last visible row while its content runs past the bottom, tracked with a `GeometryReader` and `onChange` rather than iOS 18's scroll-geometry APIs.

Not done: following `listContributed` past its first 100 collections, and the extension's fallback of browsing all open collections when the user has contributed to none.
