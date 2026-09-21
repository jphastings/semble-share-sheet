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

    /// Revokes `session`'s refresh token at the authorization server, per
    /// RFC 7009. Best effort: this never throws. A server with no
    /// revocation endpoint, a network failure, or a non-2xx response are all
    /// treated the same as success, since a failed sign-out here must never
    /// stop the user signing out locally.
    public func revoke(_ session: Session) async {
        guard let refreshToken = session.login.refreshToken?.value else { return }
        guard let issuerHost = URL(string: session.authorizationServer.issuer)?.hostName,
              let endpoint = await revocationEndpoint(issuerHost: issuerHost)
        else { return }
        let request = HTTPRequest.form(url: endpoint, fields: [
            "token": refreshToken,
            "client_id": configuration.clientID.absoluteString,
        ])
        _ = try? await http.send(request.withTimeout(Self.revocationTimeout))
    }

    /// OAuthenticator's `ServerMetadata` doesn't decode `revocation_endpoint`,
    /// so it's fetched separately from the same `.well-known` document.
    private func revocationEndpoint(issuerHost: String) async -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = issuerHost
        components.path = "/.well-known/oauth-authorization-server"
        guard let url = components.url,
              let response = try? await http.send(HTTPRequest(url: url, timeout: Self.revocationTimeout)),
              response.isSuccess,
              let metadata = try? response.decode(RevocationServerMetadata.self),
              let endpoint = URL(string: metadata.revocationEndpoint),
              // The refresh token is about to be POSTed here, so take the
              // endpoint only if the document names an https one.
              endpoint.scheme == "https"
        else { return nil }
        return endpoint
    }

    /// Sign-out waits on revocation, so it must not be able to hang.
    private static let revocationTimeout: TimeInterval = 5

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

/// Just the one field OAuthenticator's `ServerMetadata` doesn't decode.
private struct RevocationServerMetadata: Decodable {
    let revocationEndpoint: String

    enum CodingKeys: String, CodingKey {
        case revocationEndpoint = "revocation_endpoint"
    }
}
