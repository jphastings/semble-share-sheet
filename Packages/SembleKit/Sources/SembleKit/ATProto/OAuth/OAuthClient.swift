import Foundation

/// ATProto OAuth for a native, public client (https://atproto.com/specs/oauth).
///
/// The flow, in order:
///
/// 1. Resolve the account the user typed to a DID and the PDS it lives on.
/// 2. Ask the PDS which authorization server it trusts
///    (`/.well-known/oauth-protected-resource`), then fetch that server's
///    metadata (`/.well-known/oauth-authorization-server`) and check the
///    document really is about that server.
/// 3. Push the authorization request (PAR, RFC 9126) with PKCE, a random
///    `state`, a `login_hint` and a DPoP proof signed by a freshly generated
///    P-256 key. The server answers with a short-lived `request_uri`.
/// 4. Send the user to `authorization_endpoint?client_id=…&request_uri=…` in
///    the browser. They come back to our redirect URI with `code`, `state`
///    and `iss` (RFC 9207).
/// 5. Exchange the code for tokens at the token endpoint, presenting the PKCE
///    verifier and a DPoP proof from the same key. The tokens are bound to
///    that key: every later request must carry a proof it signed.
///
/// A public client has no secret. Its identity is its `client_id`, a URL to
/// a public metadata document; its security comes from PKCE, `state`, the
/// `iss` check, the DPoP key binding and refresh-token rotation.
///
/// This is an actor only so it can remember each authorization server's
/// latest DPoP nonce between calls and skip a round-trip.
public actor OAuthClient {
    private let configuration: OAuthClientConfiguration
    private let http: HTTPClient
    private let identity: IdentityResolver
    private let discovery: OAuthDiscovery
    /// Latest `DPoP-Nonce` per authorization server origin.
    private var nonces: [String: String] = [:]

    public init(configuration: OAuthClientConfiguration, http: HTTPClient = URLSessionHTTPClient()) {
        self.configuration = configuration
        self.http = http
        self.identity = IdentityResolver(http: http)
        self.discovery = OAuthDiscovery(http: http)
    }

    // MARK: - Begin

    /// Steps 1–3 above. `account` is a handle or DID, as the user typed it.
    public func beginAuthorization(account: String) async throws -> PendingAuthorization {
        let resolved = try await identity.resolve(account)
        let issuer = try await discovery.authorizationServerIssuer(forPDS: resolved.pdsURL)
        let metadata = try await discovery.metadata(forIssuer: issuer)

        let state = SecureRandom.token(bytes: 32)
        let pkce = PKCE()
        let signer = DPoPProofSigner.generate()

        let fields: [String: String] = [
            "client_id": configuration.clientIDString,
            "redirect_uri": configuration.redirectURI.absoluteString,
            "response_type": "code",
            "scope": configuration.scope,
            "state": state,
            "code_challenge": pkce.challenge,
            "code_challenge_method": PKCE.method,
            // Lets the server pre-fill (or lock) the account on its sign-in page.
            "login_hint": IdentityResolver.normalize(account),
        ]
        let response = try await sendWithDPoP(
            url: metadata.pushedAuthorizationRequestEndpoint,
            fields: fields,
            signer: signer,
            issuer: metadata.issuer
        )
        let par: PARResponse = try decodeSuccess(response, refreshing: false)

        let authorizationURL = try makeAuthorizationURL(
            endpoint: metadata.authorizationEndpoint,
            requestURI: par.requestURI
        )

        return PendingAuthorization(
            authorizationURL: authorizationURL,
            did: resolved.did,
            handle: resolved.handle,
            expiresAt: par.expiresIn.map { Date().addingTimeInterval($0) },
            state: state,
            codeVerifier: pkce.verifier,
            issuer: metadata.issuer,
            tokenEndpoint: metadata.tokenEndpoint,
            pdsURL: resolved.pdsURL,
            scope: configuration.scope,
            dpopPrivateKey: signer.privateKeyRawRepresentation,
            dpopNonce: nonces[metadata.issuer.originKey]
        )
    }

    // MARK: - Complete

    /// Step 5. `callbackURL` is the full URL the browser handed back, e.g.
    /// `io.github.jphastings:/oauth/callback?iss=…&state=…&code=…`.
    public func completeAuthorization(_ pending: PendingAuthorization, callbackURL: URL) async throws -> Session {
        let params = OAuthClient.queryParameters(of: callbackURL)

        // `state` first: a response that isn't ours tells us nothing, not even
        // that an error happened.
        guard let state = params["state"], !state.isEmpty else {
            throw OAuthError.invalidCallback("missing state")
        }
        guard state == pending.state else {
            throw OAuthError.stateMismatch
        }
        if let error = params["error"] {
            throw OAuthError.authorizationDenied(error: error, description: params["error_description"])
        }
        guard let iss = params["iss"], !iss.isEmpty else {
            throw OAuthError.invalidCallback("missing iss")
        }
        guard OAuthClient.issuerMatches(iss, pending.issuer) else {
            throw OAuthError.issuerMismatch(expected: pending.issuer.absoluteString, actual: iss)
        }
        guard let code = params["code"], !code.isEmpty else {
            throw OAuthError.invalidCallback("missing code")
        }

        let signer = try DPoPProofSigner(rawRepresentation: pending.dpopPrivateKey)
        if let nonce = pending.dpopNonce, nonces[pending.issuer.originKey] == nil {
            nonces[pending.issuer.originKey] = nonce
        }

        let fields: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": configuration.redirectURI.absoluteString,
            "client_id": configuration.clientIDString,
            "code_verifier": pending.codeVerifier,
        ]
        let response = try await sendWithDPoP(
            url: pending.tokenEndpoint,
            fields: fields,
            signer: signer,
            issuer: pending.issuer
        )
        let token: TokenResponse = try decodeSuccess(response, refreshing: false)
        try OAuthClient.validate(token, expectedDID: pending.did)
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw OAuthError.malformedResponse("no refresh token")
        }

        return Session(
            did: pending.did,
            handle: pending.handle,
            pdsURL: pending.pdsURL,
            authorizationServer: pending.issuer,
            accessToken: token.accessToken,
            refreshToken: refreshToken,
            expiresAt: token.expiresIn.map { Date().addingTimeInterval($0) },
            scope: token.scope ?? pending.scope,
            dpopPrivateKey: pending.dpopPrivateKey
        )
    }

    // MARK: - Refresh

    /// Trades the refresh token for a new access token (and, with rotation, a
    /// new refresh token). Metadata is re-fetched each time; it is one small,
    /// cacheable GET and saves persisting the token endpoint.
    ///
    /// An `invalid_grant` answer means the refresh token is dead (revoked,
    /// expired, or already used): the caller should send the user back to
    /// sign-in, so it surfaces as `OAuthError.sessionExpired`.
    public func refresh(_ session: Session) async throws -> Session {
        let metadata = try await discovery.metadata(forIssuer: session.authorizationServer)
        let signer = try DPoPProofSigner(rawRepresentation: session.dpopPrivateKey)

        let fields: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": session.refreshToken,
            "client_id": configuration.clientIDString,
        ]
        let response = try await sendWithDPoP(
            url: metadata.tokenEndpoint,
            fields: fields,
            signer: signer,
            issuer: metadata.issuer
        )
        let token: TokenResponse = try decodeSuccess(response, refreshing: true)
        try OAuthClient.validate(token, expectedDID: session.did)

        var refreshed = session
        refreshed.accessToken = token.accessToken
        // Servers that don't rotate may omit the refresh token; keep ours then.
        if let refreshToken = token.refreshToken, !refreshToken.isEmpty {
            refreshed.refreshToken = refreshToken
        }
        refreshed.expiresAt = token.expiresIn.map { Date().addingTimeInterval($0) }
        if let scope = token.scope, !scope.isEmpty {
            refreshed.scope = scope
        }
        return refreshed
    }

    // MARK: - Requests to the authorization server

    /// Sends a form-encoded POST with a DPoP proof. If the server answers
    /// `use_dpop_nonce` (it wants proofs to carry a nonce it issued, and we had
    /// none or a stale one), the request is retried once with the nonce from
    /// its `DPoP-Nonce` header. Nonces from any response are remembered for
    /// the next request to that server.
    private func sendWithDPoP(
        url: URL,
        fields: [String: String],
        signer: DPoPProofSigner,
        issuer: URL
    ) async throws -> HTTPResponse {
        let response = try await sendOnce(url: url, fields: fields, signer: signer, issuer: issuer)
        if OAuthClient.wantsNonce(response), response.header("DPoP-Nonce") != nil {
            return try await sendOnce(url: url, fields: fields, signer: signer, issuer: issuer)
        }
        return response
    }

    private func sendOnce(
        url: URL,
        fields: [String: String],
        signer: DPoPProofSigner,
        issuer: URL
    ) async throws -> HTTPResponse {
        let key = issuer.originKey
        let proof = try signer.proof(method: "POST", url: url, nonce: nonces[key])
        let request = HTTPRequest.form(url: url, fields: fields, headers: [
            "DPoP": proof,
            "Accept": "application/json",
        ])
        let response = try await http.send(request)
        if let nonce = response.header("DPoP-Nonce"), !nonce.isEmpty {
            nonces[key] = nonce
        }
        return response
    }

    private static func wantsNonce(_ response: HTTPResponse) -> Bool {
        guard response.statusCode == 400 || response.statusCode == 401 else { return false }
        let body = try? response.decode(OAuthErrorResponse.self)
        return body?.error == "use_dpop_nonce"
    }

    private func decodeSuccess<T: Decodable>(_ response: HTTPResponse, refreshing: Bool) throws -> T {
        guard response.isSuccess else {
            let body = try? response.decode(OAuthErrorResponse.self)
            let code = body?.error ?? "HTTP \(response.statusCode)"
            if refreshing, code == "invalid_grant" {
                throw OAuthError.sessionExpired
            }
            throw OAuthError.authorizationServerRejected(error: code, description: body?.errorDescription)
        }
        do {
            return try response.decode(T.self)
        } catch {
            throw OAuthError.malformedResponse(String(describing: T.self))
        }
    }

    private static func validate(_ token: TokenResponse, expectedDID: String) throws {
        guard token.tokenType.lowercased() == "dpop" else {
            throw OAuthError.unsupportedTokenType(token.tokenType)
        }
        guard let sub = token.sub, !sub.isEmpty else {
            throw OAuthError.malformedResponse("no sub")
        }
        guard sub == expectedDID else {
            throw OAuthError.subjectMismatch(expected: expectedDID, actual: sub)
        }
    }

    // MARK: - URLs

    /// `<authorization_endpoint>?client_id=…&request_uri=…`, preserving any
    /// query the endpoint already has. Values are strictly percent-encoded
    /// (`URLQueryItem` would leave `+` and friends alone).
    private func makeAuthorizationURL(endpoint: URL, requestURI: String) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidMetadata("bad authorization_endpoint")
        }
        let query = "client_id=\(configuration.clientIDString.formURLEncodedComponent)&request_uri=\(requestURI.formURLEncodedComponent)"
        if let existing = components.percentEncodedQuery, !existing.isEmpty {
            components.percentEncodedQuery = existing + "&" + query
        } else {
            components.percentEncodedQuery = query
        }
        guard let url = components.url else {
            throw OAuthError.invalidMetadata("bad authorization_endpoint")
        }
        return url
    }

    private static func queryParameters(of url: URL) -> [String: String] {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return [:]
        }
        var result: [String: String] = [:]
        for item in items {
            result[item.name] = item.value ?? ""
        }
        return result
    }

    /// Exact match, tolerating only a trailing slash.
    private static func issuerMatches(_ iss: String, _ issuer: URL) -> Bool {
        func trimmed(_ s: String) -> String {
            s.hasSuffix("/") ? String(s.dropLast()) : s
        }
        return trimmed(iss) == trimmed(issuer.absoluteString)
    }
}

// MARK: - Wire types

struct PARResponse: Decodable {
    let requestURI: String
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case requestURI = "request_uri"
        case expiresIn = "expires_in"
    }
}

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String
    let expiresIn: Double?
    let sub: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case sub
        case scope
    }
}

/// RFC 6749 §5.2 error body.
struct OAuthErrorResponse: Decodable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}
