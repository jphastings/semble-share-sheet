# Changelog

Newest first. Entries from 0.2.2 onwards are written by the release
automation from the files in `.changeset/`; see CONTRIBUTING.md.

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
