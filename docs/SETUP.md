# Setup

One-time setup for a maintainer or for a fork. You only need this if you
want to run the app on a real device, publish your own client metadata, or
ship to TestFlight; building for the Simulator needs nothing here.

## 1. Bundle identifiers and team

Everything is generated from `project.yml`. Change:

- the app bundle id (`me.byjp.SembleShare`) and the extension bundle id
  (`me.byjp.SembleShare.ShareExtension`);
- the app group (`group.me.byjp.SembleShare`) and the Keychain access group
  (`$(AppIdentifierPrefix)me.byjp.SembleShare`) in both targets'
  entitlements;
- `DEVELOPMENT_TEAM` to your Team ID.

Then `xcodegen generate`. Keep the extension's bundle id prefixed by the
app's; iOS requires it.

## 2. OAuth client metadata and GitHub Pages

ATProto OAuth identifies a client by a URL that serves its metadata
document, so the metadata has to be live before anyone can sign in.
`web/client-metadata.json` is published to GitHub Pages by
`.github/workflows/pages.yml`.

1. In the repository settings, under **Pages**, set **Source** to
   **GitHub Actions** (not "Deploy from a branch"). The workflow will fail
   until this is done.
2. Push to `main` (or run the workflow by hand). Check that
   `https://<user>.github.io/<repo>/client-metadata.json` returns the JSON.

For a fork, edit `web/client-metadata.json`:

- `client_id`, `client_uri`, `logo_uri`, `policy_uri` become your Pages URLs.
- **The redirect scheme is derived from the `client_id` host.** The
  [ATProto OAuth spec](https://atproto.com/specs/oauth#clients) requires a
  native client's custom-scheme redirect URI to be the reverse-DNS form of
  the client_id's domain: `jphastings.github.io` → `io.github.jphastings`,
  so the redirect URI is `io.github.jphastings:/oauth/callback` (note the
  single slash). Change `redirect_uris` here *and* the URL scheme registered
  by the app in `project.yml` / `Info.plist`, plus wherever the Swift code
  configures `OAuthClientConfiguration`.

`scope` must stay `atproto include:network.cosmik.authFull`; that is the
permission set Semble publishes.

## 3. Apple Developer

In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list):

1. Register two **App IDs** (explicit, not wildcard) for the app and the
   extension bundle ids. On both, enable the **App Groups** and
   **Keychain Sharing** capabilities.
2. Register an **App Group** with the id from `project.yml`
   (`group.me.byjp.SembleShare` by default) and assign it to both App IDs.
   Apple's guides: [Configuring App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)
   and [Sharing access to keychain items among a collection of apps](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps).
3. In [App Store Connect](https://appstoreconnect.apple.com), create the app
   record with the app's bundle id. TestFlight distribution needs nothing
   more than an uploaded build; see
   [docs/RELEASING.md](RELEASING.md) for the certificate, profiles and API
   key the release workflow uses, and Apple's
   [TestFlight overview](https://developer.apple.com/testflight/).

Local device builds work with automatic signing in Xcode once the App IDs
and app group exist; the manual-signing setup is only for CI.
