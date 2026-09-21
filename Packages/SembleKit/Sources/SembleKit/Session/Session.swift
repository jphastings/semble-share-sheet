import Foundation
import OAuthenticator

/// Everything needed to keep talking to a user's PDS after they have signed
/// in: who they are, where their data lives, the OAuth tokens, and the DPoP
/// key those tokens are bound to.
///
/// `ServerMetadata`, `Login` and `DPoPKey` are OAuthenticator's types. The
/// authorization server's metadata is cached here so the share extension
/// never has to repeat discovery before it can refresh a token.
///
/// Sessions are persisted by a `SessionStore` and shared between the app and
/// the share extension.
public struct Session: Codable, Equatable, Sendable {
    public var did: String
    public var handle: String?
    /// The user's personal data server, e.g. `https://bsky.social`.
    public var pdsURL: URL
    /// The OAuth authorization server that minted the tokens.
    public var authorizationServer: ServerMetadata
    /// Access and refresh tokens, expiry and the granted scope.
    public var login: Login
    /// The P-256 key the tokens are DPoP-bound to.
    public var dpopKey: DPoPKey

    public init(
        did: String,
        handle: String?,
        pdsURL: URL,
        authorizationServer: ServerMetadata,
        login: Login,
        dpopKey: DPoPKey
    ) {
        self.did = did
        self.handle = handle
        self.pdsURL = pdsURL
        self.authorizationServer = authorizationServer
        self.login = login
        self.dpopKey = dpopKey
    }

    /// True when the access token has expired and the next call will refresh.
    public var isExpired: Bool { !login.accessToken.valid }
}
