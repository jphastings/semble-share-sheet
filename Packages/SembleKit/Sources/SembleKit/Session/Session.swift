import Foundation

/// Everything needed to keep talking to a user's PDS after they have signed
/// in: who they are, where their data lives, and the OAuth tokens (plus the
/// DPoP key those tokens are bound to).
///
/// Sessions are persisted by a `SessionStore` and shared between the app and
/// the share extension.
public struct Session: Codable, Equatable, Sendable {
    public var did: String
    public var handle: String?
    /// The user's personal data server, e.g. `https://bsky.social`.
    public var pdsURL: URL
    /// The OAuth authorization server (issuer) that minted the tokens.
    public var authorizationServer: URL
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date?
    public var scope: String
    /// The P-256 private key the tokens are DPoP-bound to (raw representation).
    public var dpopPrivateKey: Data

    public init(
        did: String,
        handle: String?,
        pdsURL: URL,
        authorizationServer: URL,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date?,
        scope: String,
        dpopPrivateKey: Data
    ) {
        self.did = did
        self.handle = handle
        self.pdsURL = pdsURL
        self.authorizationServer = authorizationServer
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.dpopPrivateKey = dpopPrivateKey
    }

    /// True when the access token has expired, or will within `leeway`.
    public func isExpired(at date: Date = Date(), leeway: TimeInterval = 30) -> Bool {
        guard let expiresAt else { return false }
        return date.addingTimeInterval(leeway) >= expiresAt
    }
}
