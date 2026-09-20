# Architecture

"Add to Semble" is a small iOS app whose only real job is to put an
**Add to Semble** action in the system share sheet. It talks to the
[AT Protocol](https://atproto.com) directly: the user signs in with their
atmosphere account (Bluesky, or any other PDS) and the share extension writes
Semble's own record types into the user's repository. Semble's AppView indexes
those records from the firehose, exactly as it does for its browser extension
and web app, so a link saved here shows up on [semble.so](https://semble.so)
within a few seconds.

There is no Semble-specific backend, API key or session in the loop. The app
never sees an app password: sign-in is [ATProto OAuth](https://atproto.com/specs/oauth)
with the `include:network.cosmik.authFull` permission set, which grants write
access to exactly the `network.cosmik.*` collections Semble uses and nothing
else.

## Targets

```
semble-share-sheet/
├── SembleShare/          The container app: sign in, then "you're set up" instructions
├── ShareExtension/       The share-sheet UI ("Add to Semble")
├── Shared/               Source compiled into both targets (app configuration)
├── Packages/SembleKit/   Platform-independent Swift package: ATProto OAuth, XRPC,
│                         Semble record types and the "save a URL" workflow. All unit
│                         tests live here and run with `swift test` on macOS.
├── web/                  Static site published to GitHub Pages. Hosts the OAuth
│                         client metadata document (the app's client_id).
├── fastlane/             Build + TestFlight upload lanes
└── .github/workflows/    CI (build + test) and release (TestFlight)
```

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen); the `.xcodeproj` is not
committed.

## How a save works

1. The share extension receives a URL from the host app.
2. It loads the `Session` from the shared Keychain (app group access group).
3. It asks Semble's public `network.cosmik.card.getUrlMetadata` endpoint for a
   title/description/image so the sheet can show a preview. This is the one
   call to `api.semble.so`; it needs no authentication and failure is
   non-fatal.
4. It lists the user's `network.cosmik.collection` records from their PDS
   (`com.atproto.repo.listRecords`) to populate the collection picker.
5. On **Add**, it creates, in order:
   - a `network.cosmik.card` record of type `URL`;
   - if a note was entered, a `network.cosmik.card` record of type `NOTE`
     whose `parentCard` is a strong ref to the URL card;
   - one `network.cosmik.collectionLink` record per chosen collection, each
     holding strong refs to the collection and the card.

   Any collection the user creates from the picker becomes a
   `network.cosmik.collection` record first.

Record shapes mirror the lexicons in
[cosmik-network/semble](https://github.com/cosmik-network/semble/tree/main/src/modules/atproto/infrastructure/lexicons)
and the mappers Semble's own backend uses when it publishes to a PDS.

## SembleKit public API

The package is split into layers. Each layer only depends on the ones above
it, and `HTTPClient` is the sole seam to the network so every layer is
testable with a stub.

### Support

```swift
public struct HTTPRequest / HTTPResponse
public protocol HTTPClient { func send(_ request: HTTPRequest) async throws -> HTTPResponse }
public struct URLSessionHTTPClient: HTTPClient
```

### Session

```swift
public struct Session: Codable            // did, handle, pdsURL, authorizationServer, tokens, scope, dpopPrivateKey
public protocol SessionStore              // load() / save(_:) / clear()
public final class InMemorySessionStore   // tests and previews
public final class KeychainSessionStore   // init(service: String, accessGroup: String?)
```

### ATProto

```swift
public struct StrongRef { uri, cid }
public struct ATURI { did, collection, rkey }

public struct ResolvedIdentity { did: String; handle: String?; pdsURL: URL }
public struct IdentityResolver {
    public init(http: HTTPClient = URLSessionHTTPClient())
    /// Accepts a handle ("alice.bsky.social") or a DID ("did:plc:…", "did:web:…").
    public func resolve(_ account: String) async throws -> ResolvedIdentity
}

public struct OAuthClientConfiguration { clientID: URL; redirectURI: URL; scope: String }

/// Opaque, Codable state between opening the browser and receiving the callback.
public struct PendingAuthorization: Codable { public let authorizationURL: URL /* + private state */ }

public actor OAuthClient {
    public init(configuration: OAuthClientConfiguration, http: HTTPClient = URLSessionHTTPClient())
    public func beginAuthorization(account: String) async throws -> PendingAuthorization
    public func completeAuthorization(_ pending: PendingAuthorization, callbackURL: URL) async throws -> Session
    public func refresh(_ session: Session) async throws -> Session
}

public struct RecordEnvelope<Record: Decodable> { uri: String; cid: String; value: Record }
public struct RecordPage<Record: Decodable> { records: [RecordEnvelope<Record>]; cursor: String? }

/// Authenticated XRPC calls against the session's own PDS. Adds DPoP proofs,
/// handles `use_dpop_nonce` retries, and refreshes an expired access token
/// (persisting the new session to the store) transparently.
public actor PDSClient {
    public init(session: Session, sessionStore: SessionStore, oauth: OAuthClient, http: HTTPClient = URLSessionHTTPClient())
    public var did: String { get async }
    public func createRecord<R: Encodable>(collection: String, record: R) async throws -> StrongRef
    public func listRecords<R: Decodable>(collection: String, limit: Int = 100, cursor: String? = nil) async throws -> RecordPage<R>
    public func getRecord<R: Decodable>(collection: String, rkey: String) async throws -> RecordEnvelope<R>
    public func deleteRecord(collection: String, rkey: String) async throws
}
```

### Semble

```swift
public struct SembleConfiguration {
    cardCollection, collectionCollection, collectionLinkCollection: String
    apiBaseURL: URL      // https://api.semble.so/xrpc
    websiteURL: URL      // https://semble.so
    public static let production: SembleConfiguration
}

public enum CollectionAccessType: String, Codable { case open = "OPEN", closed = "CLOSED" }

public struct CollectionSummary: Identifiable, Hashable {
    public var id: String { ref.uri }
    public let ref: StrongRef
    public let name: String
    public let accessType: CollectionAccessType
    public let description: String?
}

public struct URLPreview: Codable, Equatable {
    url: URL; title, description, siteName, type: String?; imageURL: URL?
}

public struct URLMetadataClient {
    public init(configuration: SembleConfiguration = .production, http: HTTPClient = URLSessionHTTPClient())
    public func preview(for url: URL) async throws -> URLPreview
}

public struct SaveRequest { url: URL; preview: URLPreview?; note: String?; collections: [StrongRef] }
public struct SaveResult { card: StrongRef; note: StrongRef?; collectionLinks: [StrongRef] }

/// What the share sheet needs from Semble. A protocol so the UI can be
/// previewed and tested without a network.
public protocol Library: Sendable {
    func myCollections() async throws -> [CollectionSummary]
    func createCollection(named name: String, accessType: CollectionAccessType) async throws -> CollectionSummary
    func save(_ request: SaveRequest) async throws -> SaveResult
}

public actor SembleLibrary: Library {
    public init(pds: PDSClient, configuration: SembleConfiguration = .production)
}

// Record types (Codable, `$type` included), used by SembleLibrary and tests:
public struct CardRecord, CollectionRecord, CollectionLinkRecord
```

## Errors

Every public error type conforms to `LocalizedError` with a short,
user-presentable `errorDescription`. The UI shows `error.localizedDescription`
and nothing else, so messages must make sense to a person ("Couldn't reach
bsky.social", not "HTTP 502").

## Code style

- Swift 5 language mode with strict-concurrency warnings on; `Sendable` where
  it is natural, `actor` for anything holding mutable network state.
- No third-party dependencies. `CryptoKit` provides ES256 (DPoP) and SHA-256
  (PKCE). The share extension has a tight memory budget and every dependency
  is something a reviewer has to audit.
- Tests assert on behaviour and intent ("a refresh persists the rotated
  refresh token", "a PAR rejected with `use_dpop_nonce` is retried once with
  the nonce"), not on exact byte layouts.
