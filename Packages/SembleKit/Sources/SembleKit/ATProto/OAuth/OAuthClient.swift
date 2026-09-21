import Foundation
import OAuthenticator

/// Signs a user in with ATProto OAuth.
///
/// The heavy lifting (PAR, PKCE, DPoP-bound tokens, nonce retries) is
/// OAuthenticator's `Bluesky` flow. This type does the parts ATProto adds
/// around it: resolving the account to a DID and PDS, discovering the PDS's
/// authorization server, checking the issued token is for the account that
/// was typed, and packaging the result as a `Session`.
public actor OAuthClient {
    private let configuration: OAuthClientConfiguration
    private let http: HTTPClient

    public init(configuration: OAuthClientConfiguration, http: HTTPClient = URLSessionHTTPClient()) {
        self.configuration = configuration
        self.http = http
    }

    /// Runs the whole sign-in for `account` (a handle or DID).
    ///
    /// `openBrowser` is given the authorization URL and the callback scheme
    /// and must return the callback URL the browser was redirected to; in the
    /// app that is SwiftUI's `WebAuthenticationSession`. Errors from it (such
    /// as the user cancelling) are rethrown untouched.
    public func signIn(account: String, openBrowser: @escaping Authenticator.UserAuthenticator) async throws -> Session {
        let identity = try await IdentityResolver(http: http).resolve(account)
        let provider = http.urlResponseProvider
        let server = try await Self.discoverAuthorizationServer(for: identity.pdsURL, provider: provider)

        let key = DPoPKey.P256()
        let expectedDID = identity.did
        let tokenHandling = Bluesky.tokenHandling(
            account: identity.handle ?? identity.did,
            server: server,
            jwtGenerator: DPoPProofs.generator(for: key),
            validator: { response, _ in response.sub == expectedDID }
        )
        let authenticator = Authenticator(
            config: Authenticator.Configuration(
                appCredentials: configuration.appCredentials,
                loginStorage: nil,
                tokenHandling: tokenHandling,
                mode: .manualOnly,
                userAuthenticator: openBrowser
            ),
            urlLoader: provider
        )

        let login: Login
        do {
            login = try await authenticator.authenticate()
        } catch {
            throw OAuthError.fromAuthenticator(error)
        }

        return Session(
            did: identity.did,
            handle: identity.handle,
            pdsURL: identity.pdsURL,
            authorizationServer: server,
            login: login,
            dpopKey: key
        )
    }

    /// Finds the authorization server for a PDS: the PDS's protected-resource
    /// document names it, and its own metadata document must agree that it
    /// is who we fetched it from.
    static func discoverAuthorizationServer(for pdsURL: URL, provider: @escaping URLResponseProvider) async throws -> ServerMetadata {
        guard let pdsHost = pdsURL.hostName else {
            throw OAuthError.discoveryFailed(pdsURL.absoluteString)
        }
        let resource: ProtectedResourceMetadata
        do {
            resource = try await ProtectedResourceMetadata.load(for: pdsHost, provider: provider)
        } catch {
            throw OAuthError.discoveryFailed(pdsHost)
        }
        guard let issuerString = resource.authorizationServers?.first,
              let issuerHost = URL(string: issuerString)?.hostName
        else {
            throw OAuthError.discoveryFailed(pdsHost)
        }

        let server: ServerMetadata
        do {
            server = try await ServerMetadata.load(for: issuerHost, provider: provider)
        } catch {
            throw OAuthError.discoveryFailed(issuerHost)
        }
        // The spec requires the issuer to be exactly the origin the document
        // was served from; a server claiming to be another one is not trusted.
        guard let issuer = URLComponents(string: server.issuer),
              issuer.scheme == "https",
              issuer.host?.lowercased() == issuerHost.lowercased(),
              issuer.path.isEmpty || issuer.path == "/",
              issuer.query == nil, issuer.fragment == nil
        else {
            throw OAuthError.issuerMismatch
        }
        return server
    }
}

extension URL {
    /// The host name, without the deprecation noise of `URL.host`.
    var hostName: String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.host
    }
}
