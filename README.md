# Add to Semble

An iOS app whose only job is to put an **Add to Semble** action in the share
sheet. Share a link from Safari or any other app, pick a collection, add a note
if you like, and it lands in your [Semble](https://semble.so) library a few
seconds later. It talks to the AT Protocol directly (sign in with your
Bluesky or other atmosphere account) and writes Semble's own record types to
your repository, so there is no middle-man server and nothing to trust but
your own PDS.

This is an independent, unofficial app; see the [trademark note](#trademarks)
below.

## Screenshots

_Coming soon: the share sheet, the collection picker, and the result on
semble.so._

## How it works

- You sign in once with [ATProto OAuth](https://atproto.com/specs/oauth).
  The app never sees a password or app password; tokens live in the iOS
  Keychain, shared with the extension through an app group.
- The share extension writes `network.cosmik.card`,
  `network.cosmik.collectionLink` (and, if needed, `network.cosmik.collection`)
  records straight to your PDS, mirroring the lexicons in
  [cosmik-network/semble](https://github.com/cosmik-network/semble).
- Semble's AppView indexes those records from the firehose, exactly as it
  does for its own [browser extension](https://github.com/cosmik-network/extension-semble).

Details, including the package API, are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Permissions

Sign-in requests the scope `atproto include:network.cosmik.authFull`. The
`network.cosmik.authFull` permission set is published by Semble at
`at://did:plc:b2p6rujcgpenbtcjposmjuc3/com.atproto.lexicon.schema/network.cosmik.authFull`
and grants write access to the `network.cosmik.*` collections and nothing
else. The only Semble endpoint the app calls is the public, unauthenticated
`network.cosmik.card.getUrlMetadata`, for link previews. The
[privacy notice](https://jphastings.github.io/semble-share-sheet/privacy.html)
lists every host the app contacts.

## Install

TestFlight: _link coming soon_.

Until then, build it yourself.

## Building locally

You need Xcode 16 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate            # or: make generate
open SembleShare.xcodeproj   # or: make open
```

The `.xcodeproj` is generated from `project.yml` and is not committed. To run
on a device you will need to change the bundle identifiers and team to your
own; [docs/SETUP.md](docs/SETUP.md) explains what to change.

All unit tests are in the `SembleKit` package and run without Xcode:

```sh
make test   # swift test --package-path Packages/SembleKit
```

## Project layout

```
SembleShare/          Container app: sign in, then "you're set up"
ShareExtension/       The share-sheet UI
Shared/               Source compiled into both targets
Packages/SembleKit/   ATProto OAuth, XRPC, Semble records, the save workflow, and all tests
web/                  GitHub Pages site: OAuth client metadata, landing page, privacy notice
Design/               Logo source and the icon renderer
fastlane/             `test` and `beta` (TestFlight) lanes
.github/workflows/    ci.yml (build + test), release.yml (TestFlight), pages.yml (website)
docs/                 ARCHITECTURE, SETUP, RELEASING
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Maintainer docs:
[docs/SETUP.md](docs/SETUP.md) (one-time setup for a fork) and
[docs/RELEASING.md](docs/RELEASING.md) (shipping to TestFlight).

## Licence

[MIT](LICENSE) © 2026 JP Hastings.

## Trademarks

"Semble" and the Semble logo belong to
[Cosmik Network](https://cosmik.network) / Homeworld Collective Inc. This app
is independent and unofficial, and is not affiliated with or endorsed by
them. The logo in `Design/icon.svg` is reproduced under the MIT licence of
[cosmik-network/extension-semble](https://github.com/cosmik-network/extension-semble);
the record formats follow [cosmik-network/semble](https://github.com/cosmik-network/semble).
