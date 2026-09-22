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
5. On **Add**, it builds a `PendingSave` (the URL, note, chosen collections,
   any collection created from the picker and not yet on the PDS, and a
   client-chosen ATProto TID rkey for each record it will write), enqueues it
   in the app-group `SaveQueue`, and tries it immediately. If the PDS is
   unreachable the item stays queued and the sheet still dismisses; nothing
   is lost. Writing a `PendingSave` creates, in order:
   - a `network.cosmik.collection` record for each collection the save is
     creating (see "Creating a collection" below);
   - a `network.cosmik.card` record of type `URL`;
   - if a note was entered, a `network.cosmik.card` record of type `NOTE`
     whose `parentCard` is a strong ref to the URL card;
   - one `network.cosmik.collectionLink` record per chosen collection
     (existing or just created), each holding strong refs to the collection
     and the card.

   Because every record is created with its rkey chosen up front, writing the
   same `PendingSave` twice — a retry, or a drain racing a retry — is safe:
   `SembleLibrary` treats a rejected create at an already-used rkey as
   "already written" and adopts the existing record instead of duplicating
   it. The share extension can die the moment its sheet closes, so nothing
   about this relies on the process surviving; the app (on foreground) and
   the extension (on open) both drain whatever is left in the queue for the
   signed-in DID.

   **Creating a collection** from the picker is local and instant, online or
   offline — one code path, no network call: it mints a `PendingCollection`
   (name, access type and a client-chosen rkey, so its AT-URI is known
   before it exists), shows it in the picker and selects it. Nothing is
   written until a save that uses it actually reaches `SembleLibrary.save`,
   which writes it before the card — so a collection created and then
   deselected, or created in a sheet that's cancelled, is simply never
   written. A collection created by one still-queued save is offered again
   in any other sheet for the same DID (`SaveQueue.pendingCollections`),
   carrying the same rkey, so two saves that both pick it don't create it
   twice — whichever syncs first writes it and the other adopts it.

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
/// Everything the share extension needs to keep writing to the user's PDS.
/// `ServerMetadata`, `Login` and `DPoPKey` are OAuthenticator's types; the
/// authorization-server metadata is cached here so the extension never has
/// to re-run discovery.
public struct Session: Codable, Equatable, Sendable {
    did: String; handle: String?; pdsURL: URL
    authorizationServer: ServerMetadata
    login: Login          // access + refresh tokens, expiry, granted scope
    dpopKey: DPoPKey      // the P-256 key the tokens are bound to
}
public protocol SessionStore              // load() / save(_:) / clear()
public final class InMemorySessionStore   // tests and previews
public final class KeychainSessionStore   // init(service: String, accessGroup: String?)
```

### ATProto

OAuth, DPoP and PKCE are delegated to
[OAuthenticator](https://github.com/ATProtoKit/OAuthenticator) (its
`Bluesky` service implements the ATProto flavour: PAR, DPoP-bound tokens,
per-origin nonce retries, refresh) with
[Jot](https://github.com/ATProtoKit/Jot) signing the DPoP proof JWTs.
SembleKit adds only what those libraries leave to the app: resolving a
handle to a DID and PDS, discovering the PDS's authorization server, the
proof-JWT claims ATProto wants, and a thin XRPC wrapper.

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

/// Signs in: resolves the account, discovers its authorization server and
/// runs OAuthenticator's Bluesky flow. `openBrowser` is handed the
/// authorization URL and the callback scheme and returns the callback URL
/// (in the app that is SwiftUI's `WebAuthenticationSession`).
public actor OAuthClient {
    public init(configuration: OAuthClientConfiguration, http: HTTPClient = URLSessionHTTPClient())
    public func signIn(account: String, openBrowser: @escaping Authenticator.UserAuthenticator) async throws -> Session
}

/// Builds OAuthenticator's `DPoPSigner.JWTGenerator` for a key: an ES256
/// `dpop+jwt` carrying jti, iat, htm, htu and, when given, nonce and ath.
public enum DPoPProofs {
    public static func generator(for key: DPoPKey) -> DPoPSigner.JWTGenerator
}

public struct RecordEnvelope<Record: Decodable> { uri: String; cid: String; value: Record }
public struct RecordPage<Record: Decodable> { records: [RecordEnvelope<Record>]; cursor: String? }

/// Authenticated XRPC calls against the session's own PDS, made through an
/// OAuthenticator `Authenticator` in manual-only mode: it adds the DPoP
/// proof and `Authorization` header, retries on `use_dpop_nonce`, refreshes
/// an expired access token and writes the rotated session back to the
/// store. It never opens a browser; a dead refresh token surfaces as
/// `OAuthError.sessionExpired` and the stored session is cleared. A dropped
/// connection surfaces as a plain `URLError` — nothing here wraps it.
public actor PDSClient {
    public init(session: Session, sessionStore: SessionStore, configuration: OAuthClientConfiguration, http: HTTPClient = URLSessionHTTPClient())
    public var did: String { get async }
    /// `rkey` is omitted from the request when `nil` (the PDS assigns the
    /// key); passing one makes the write idempotent — see `TID`.
    public func createRecord<R: Encodable>(collection: String, record: R, rkey: String? = nil) async throws -> StrongRef
    public func listRecords<R: Decodable>(collection: String, limit: Int = 100, cursor: String? = nil) async throws -> RecordPage<R>
    public func getRecord<R: Decodable>(collection: String, rkey: String) async throws -> RecordEnvelope<R>
    public func deleteRecord(collection: String, rkey: String) async throws
}

/// ATProto Timestamp Identifiers: 13-character, base32-sortable, k-sortable
/// record keys. `SembleLibrary` mints one per record so every write it makes
/// is idempotent.
public enum TID {
    public static func next(now: Date = Date()) -> String
}

public enum OAuthError: LocalizedError { sessionExpired, issuerMismatch, subjectMismatch, discoveryFailed(String) … }
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

/// Exactly one of `ref`/`pending` is set: `ref` for a collection with a PDS
/// record, `pending` for one created locally and not yet written — which has
/// no cid, so there is deliberately no way to build a `StrongRef` for it.
public struct CollectionSummary: Identifiable, Hashable {
    public let id: String       // = ref.uri, or pending's would-be uri
    public let ref: StrongRef?
    public let pending: PendingCollection?
    public let name: String
    public let accessType: CollectionAccessType
    public let description: String?
}

/// A collection created locally and not yet written to the PDS. `rkey` is
/// chosen up front (like `PendingSave`'s own rkeys) so its AT-URI is known
/// before it exists, letting it be selected and linked right away.
public struct PendingCollection: Codable, Equatable, Hashable, Sendable {
    public let rkey: String
    public var name: String
    public var accessType: CollectionAccessType
    public let createdAt: Date
    public func uri(did: String, configuration: SembleConfiguration = .production) -> String
}

public struct URLPreview: Codable, Equatable {
    url: URL; title, description, siteName, type: String?; imageURL: URL?
}

public struct URLMetadataClient {
    public init(configuration: SembleConfiguration = .production, http: HTTPClient = URLSessionHTTPClient())
    public func preview(for url: URL) async throws -> URLPreview
}

/// Persisted intent to save a URL: everything `Library.save(_:)` needs, plus
/// the rkeys chosen for it, so writing it twice is safe. `savedAt` is the
/// moment the user tapped Save — it becomes every record's
/// `createdAt`/`addedAt`, not the time the write actually reaches the PDS.
public struct PendingSave: Codable, Equatable, Sendable {
    public let id: UUID; public let did: String
    public var url: URL; public var preview: URLPreview?; public var note: String?
    public var collections: [StrongRef]; public var newCollections: [PendingCollection]
    public let savedAt: Date
    public var cardRkey: String; public var noteRkey: String; public var linkRkeys: [String: String]
    public init(id: UUID = UUID(), did: String, url: URL, preview: URLPreview? = nil, note: String? = nil, collections: [StrongRef] = [], newCollections: [PendingCollection] = [], savedAt: Date = Date(), cardRkey: String? = nil, noteRkey: String? = nil, linkRkeys: [String: String] = [:])
    /// Mints an rkey for any collection in `collections`/`newCollections`
    /// that doesn't have one yet; existing ones are left alone.
    public mutating func ensureLinkRkeys()
}
public struct SaveResult { card: StrongRef; note: StrongRef?; collectionLinks: [StrongRef] }

/// What the share sheet needs from Semble. A protocol so the UI can be
/// previewed and tested without a network.
public protocol Library: Sendable {
    func myCollections() async throws -> [CollectionSummary]
    /// Writes `pending`'s new collections, card, note and collection links,
    /// in that order. Safe to call more than once for the same
    /// `PendingSave`: its rkeys make every write idempotent, so a retry or a
    /// drain racing a retry never duplicates a record.
    func save(_ pending: PendingSave) async throws -> SaveResult
}

public actor SembleLibrary: Library {
    public init(pds: PDSClient, configuration: SembleConfiguration = .production)
}

// Record types (Codable, `$type` included), used by SembleLibrary and tests:
public struct CardRecord, CollectionRecord, CollectionLinkRecord
```

### Offline saves

```swift
/// One JSON file per pending save in the app-group container. A file's
/// extension is its state: `<id>.json` queued, `<id>.inflight` claimed by
/// whichever process is currently trying it (an atomic rename, so two
/// processes racing to claim the same item can't both win), `<id>.failed`
/// given up on (a permanent failure found during a drain — there's no
/// app-side list to show it yet).
public final class SaveQueue {
    public init(directory: URL)
    public func enqueue(_ pending: PendingSave) throws
    public func remove(_ id: UUID)
    enum Attempt: Equatable { case saved, queued, failed(String) }
    /// Claims and tries `pending` once, right away. A permanent failure
    /// removes the item (the caller is showing the error live); a
    /// transient one releases the claim so the item stays queued.
    @discardableResult func attempt(_ pending: PendingSave, using library: any Library) async -> Attempt
    /// Tries every item queued for `did`; another DID's items are left
    /// completely untouched. A permanent failure is parked as `.failed`.
    func drain(for did: String, using library: any Library) async
    /// Collections created by saves still waiting to sync for `did` — so a
    /// second sheet can offer one an earlier, still-offline save already
    /// created instead of risking a duplicate.
    func pendingCollections(for did: String) -> [PendingCollection]
}

/// The last-known collection list per DID, cached in the app-group container
/// so the picker has something to show before (or instead of) a network
/// round trip.
public final class CollectionsCache {
    public init(directory: URL)
    public func load(for did: String) -> [CollectionSummary]?
    public func save(_ collections: [CollectionSummary], for did: String)
}
```

`ShareSheetModel.save()` builds a `PendingSave`, enqueues it, and calls
`SaveQueue.attempt` right away — claiming it exactly like any other drain
would, so the share extension's own save and a background drain can never
both write the same item. A reachable PDS ends `.saved`; an unreachable one
ends a new `.queued` phase (the sheet still dismisses; the item stays on
disk); a permanent failure (bad URL, note too long, a non-session 4xx) ends
`.failed` as before, with the item removed from the queue — the user is
looking at the message and a retry re-enqueues the same `PendingSave`.
`ShareSheetModel.load()` shows a cached collection list immediately if one
exists, then replaces it from the network; a transient refresh failure
leaves the cache (or an empty list) on screen instead of failing the sheet,
since saving without collections has to work offline.

Who drains: the share extension, in the background as its sheet opens
(before/alongside its own save); the app, when `scenePhase` becomes
`.active` while signed in. Both go through the same `SaveQueue`, keyed by
the app group, so either can pick up what the other left behind.

## Errors

Every public error type conforms to `LocalizedError` with a short,
user-presentable `errorDescription`. The UI shows `error.localizedDescription`
and nothing else, so messages must make sense to a person ("Couldn't reach
bsky.social", not "HTTP 502").

## Code style

- Swift 5 language mode with strict-concurrency warnings on; `Sendable` where
  it is natural, `actor` for anything holding mutable network state.
- Dependencies are kept to the security-sensitive parts we should not be
  hand-rolling: OAuthenticator (OAuth 2.1 + DPoP) and Jot (JWT/JWK), both
  from the ATProtoKit organisation, both dependency-free themselves. The
  share extension has a tight memory budget and every dependency is
  something a reviewer has to audit, so anything else stays in-tree.
- Tests assert on behaviour and intent ("a refresh persists the rotated
  refresh token", "a PAR rejected with `use_dpop_nonce` is retried once with
  the nonce"), not on exact byte layouts.

## Related docs

[SETUP.md](SETUP.md) (one-time setup for a fork or maintainer) · [RELEASING.md](RELEASING.md) (TestFlight via GitHub Actions) · [Design/README.md](../Design/README.md) (icon source and licence)
