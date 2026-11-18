# Changelog

Newest first. Entries from 0.2.2 onwards are written by the release
automation from the files in `.changeset/`; see CONTRIBUTING.md.

## 0.2.5 (2026-11-18)

### Features

- You can now add links to other people's open collections. The collection list shows yours under "Mine" and the open collections you've added to under "Shared", and searching also finds anyone's open collections. The list now fills the sheet and fades at the bottom when there's more to scroll.

### Fixes

- A link saved after your sign-in has expired is no longer stuck on your device: the share sheet now says you need to log in again, and the link is added as soon as you do. If your sign-in expires while the app is open, it now shows the sign-in screen instead of looking signed in.
- Fixed a rare case where using the share sheet while the app was syncing could sign you out.

## 0.2.4 (2026-09-22)

### Features

- You can now create a new collection while offline — it's picked instantly and saved to your PDS along with the link once you're back online.

## 0.2.3 (2026-09-22)

### Fixes

- On a poor connection, a save now falls back to "will add when you're online" within seconds instead of spinning for up to a minute.

## 0.2.2 (2026-09-22)

### Features

- Saving now works with no or spotty connectivity: a link you add while offline is kept on your device and sent to your PDS as soon as the app or the share sheet is next online, and your collections are cached so you can still pick them without a connection.
- A link carrying a query string, a fragment or a username now waits for you to ask before its preview is fetched, so a private or single-use link is not sent anywhere you did not choose. Previews also no longer hold up the share sheet, and thumbnails load only over https.
- Retrying a save that failed part way through no longer adds a second copy of the link to your library.
- Signing out now revokes your tokens with your server rather than only forgetting them, and tells you if it could not. Reinstalling the app no longer leaves you signed in as whoever used it last.

## 0.2.1

Releases up to and including this one predate the changelog. See the git tags
for what shipped in them.
