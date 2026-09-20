import Foundation

/// Everything `OAuthClient` needs to finish a sign-in once the browser
/// returns. Created by `beginAuthorization`, consumed by
/// `completeAuthorization`.
///
/// It is `Codable` because the app may be suspended (or killed) while the
/// browser is in front; the app persists it and hands it back on the
/// callback. Treat it as a secret: it holds the PKCE verifier and the DPoP
/// private key.
public struct PendingAuthorization: Codable, Equatable, Sendable {
    /// Open this in the browser (`ASWebAuthenticationSession`).
    public let authorizationURL: URL
    /// The account the sign-in is for, as resolved before starting.
    public let did: String
    public let handle: String?
    /// When the authorization server will stop accepting the pushed request;
    /// past this the user has to start over.
    public let expiresAt: Date?

    // Private state, checked or spent when the callback arrives.
    let state: String
    let codeVerifier: String
    let issuer: URL
    let tokenEndpoint: URL
    let pdsURL: URL
    let scope: String
    /// `P256.Signing.PrivateKey.rawRepresentation` of the DPoP key.
    let dpopPrivateKey: Data
    /// The authorization server's latest `DPoP-Nonce`, if it issued one
    /// during PAR. Purely an optimisation: if it's missing or stale the token
    /// request is simply retried with a fresh one.
    let dpopNonce: String?

    init(
        authorizationURL: URL,
        did: String,
        handle: String?,
        expiresAt: Date?,
        state: String,
        codeVerifier: String,
        issuer: URL,
        tokenEndpoint: URL,
        pdsURL: URL,
        scope: String,
        dpopPrivateKey: Data,
        dpopNonce: String?
    ) {
        self.authorizationURL = authorizationURL
        self.did = did
        self.handle = handle
        self.expiresAt = expiresAt
        self.state = state
        self.codeVerifier = codeVerifier
        self.issuer = issuer
        self.tokenEndpoint = tokenEndpoint
        self.pdsURL = pdsURL
        self.scope = scope
        self.dpopPrivateKey = dpopPrivateKey
        self.dpopNonce = dpopNonce
    }
}
