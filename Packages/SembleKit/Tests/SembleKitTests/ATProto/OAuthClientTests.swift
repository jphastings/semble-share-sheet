import CryptoKit
import XCTest
@testable import SembleKit

final class OAuthClientTests: XCTestCase {
    private var stub: StubHTTPClient!
    private var client: OAuthClient!

    override func setUp() {
        super.setUp()
        stub = StubHTTPClient()
        client = OAuthClient(configuration: Fixtures.configuration, http: stub)
    }

    // MARK: - Helpers

    /// Stubs everything `beginAuthorization` touches, with a PAR endpoint that
    /// just accepts.
    private func stubHappyPath() {
        stub.stubIdentity()
        stub.stubOAuthDiscovery()
        stub.on(Fixtures.parEndpoint, status: 201, json: #"{"request_uri": "urn:ietf:params:oauth:request_uri:req-1", "expires_in": 90}"#)
    }

    private func callbackURL(state: String, code: String = "code-1", iss: String = Fixtures.issuer.absoluteString) -> URL {
        var components = URLComponents(url: Fixtures.redirectURI, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "iss", value: iss),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code", value: code),
        ]
        return components.url!
    }

    // MARK: - beginAuthorization

    func test_beginAuthorizationDiscoversTheServersAndPushesTheRequest() async throws {
        stubHappyPath()

        let pending = try await client.beginAuthorization(account: "@Alice.example.com")

        // Discovery: PDS → protected resource → auth server metadata.
        XCTAssertEqual(stub.requests(to: "https://pds.example/.well-known/oauth-protected-resource").count, 1)
        XCTAssertEqual(stub.requests(to: "https://auth.example/.well-known/oauth-authorization-server").count, 1)

        // PAR carried PKCE (S256), our scope, state and a login hint.
        let par = try XCTUnwrap(stub.requests(to: Fixtures.parEndpoint).last)
        XCTAssertEqual(par.method, "POST")
        XCTAssertEqual(par.headers["Content-Type"], "application/x-www-form-urlencoded")
        let fields = formFields(of: par)
        XCTAssertEqual(fields["client_id"], Fixtures.clientID.absoluteString)
        XCTAssertEqual(fields["redirect_uri"], Fixtures.redirectURI.absoluteString)
        XCTAssertEqual(fields["response_type"], "code")
        XCTAssertEqual(fields["scope"], Fixtures.scope)
        XCTAssertEqual(fields["code_challenge_method"], "S256")
        XCTAssertEqual(fields["login_hint"], "alice.example.com")
        XCTAssertEqual(fields["state"], pending.state)
        XCTAssertEqual(fields["code_challenge"], PKCE.challenge(for: pending.codeVerifier))

        // PAR was DPoP-signed by the key the pending authorization keeps.
        let proof = try XCTUnwrap(DecodedProof(par.headers["DPoP"]))
        XCTAssertEqual(proof.payload["htm"] as? String, "POST")
        XCTAssertEqual(proof.payload["htu"] as? String, Fixtures.parEndpoint)
        XCTAssertNil(proof.payload["ath"], "no access token yet")
        let pendingKey = try P256.Signing.PrivateKey(rawRepresentation: pending.dpopPrivateKey)
        XCTAssertTrue(proof.isSigned(by: pendingKey.publicKey))

        // The browser URL points at the authorization endpoint with our request.
        XCTAssertTrue(pending.authorizationURL.absoluteString.hasPrefix(Fixtures.authorizeEndpoint + "?"))
        let query = queryParameters(of: pending.authorizationURL)
        XCTAssertEqual(query["client_id"], Fixtures.clientID.absoluteString)
        XCTAssertEqual(query["request_uri"], "urn:ietf:params:oauth:request_uri:req-1")

        XCTAssertEqual(pending.did, Fixtures.did)
        XCTAssertEqual(pending.handle, Fixtures.handle)
        XCTAssertEqual(pending.pdsURL, Fixtures.pdsURL)
        XCTAssertEqual(pending.issuer, Fixtures.issuer)
        XCTAssertNotNil(pending.expiresAt)
    }

    func test_parIsRetriedOnceWithServerNonce() async throws {
        stub.stubIdentity()
        stub.stubOAuthDiscovery()
        // A server that insists on a nonce: reject any proof without one.
        stub.on(Fixtures.parEndpoint) { request in
            guard DecodedProof(request.headers["DPoP"])?.nonce == "nonce-1" else {
                return Fixtures.useDPoPNonce("nonce-1")
            }
            return HTTPResponse(statusCode: 201, body: Data(#"{"request_uri": "urn:ietf:params:oauth:request_uri:req-2", "expires_in": 90}"#.utf8))
        }

        let pending = try await client.beginAuthorization(account: Fixtures.handle)

        let parRequests = stub.requests(to: Fixtures.parEndpoint)
        XCTAssertEqual(parRequests.count, 2)
        XCTAssertNil(DecodedProof(parRequests[0].headers["DPoP"])?.nonce)
        XCTAssertEqual(DecodedProof(parRequests[1].headers["DPoP"])?.nonce, "nonce-1")
        XCTAssertEqual(queryParameters(of: pending.authorizationURL)["request_uri"], "urn:ietf:params:oauth:request_uri:req-2")
        XCTAssertEqual(pending.dpopNonce, "nonce-1", "remembered for the token request")
    }

    func test_parIsNotRetriedForever() async {
        stub.stubIdentity()
        stub.stubOAuthDiscovery()
        stub.on(Fixtures.parEndpoint) { _ in Fixtures.useDPoPNonce("nonce-again") }

        let error = await errorThrown { try await client.beginAuthorization(account: Fixtures.handle) }

        XCTAssertEqual(stub.requests(to: Fixtures.parEndpoint).count, 2)
        XCTAssertEqual(error as? OAuthError, .authorizationServerRejected(error: "use_dpop_nonce", description: "Authorization server requires nonce in DPoP proof"))
    }

    func test_beginAuthorizationRejectsMetadataFromAnotherIssuer() async {
        stub.stubIdentity()
        stub.stubOAuthDiscovery(metadataIssuer: URL(string: "https://evil.example")!)

        let error = await errorThrown { try await client.beginAuthorization(account: Fixtures.handle) }

        XCTAssertEqual(error as? OAuthError, .issuerMismatch(expected: "https://auth.example", actual: "https://evil.example"))
        XCTAssertTrue(stub.requests(to: Fixtures.parEndpoint).isEmpty)
    }

    func test_beginAuthorizationSurfacesAServersRefusal() async {
        stub.stubIdentity()
        stub.stubOAuthDiscovery()
        stub.on(Fixtures.parEndpoint, status: 400, json: #"{"error": "invalid_client_metadata", "error_description": "Client metadata could not be fetched"}"#)

        let error = await errorThrown { try await client.beginAuthorization(account: Fixtures.handle) }

        XCTAssertEqual(error?.localizedDescription, "Client metadata could not be fetched")
    }

    // MARK: - completeAuthorization

    func test_completeAuthorizationRejectsAStateMismatch() async throws {
        stubHappyPath()
        let pending = try await client.beginAuthorization(account: Fixtures.handle)

        let error = await errorThrown {
            try await client.completeAuthorization(pending, callbackURL: callbackURL(state: "not-our-state"))
        }

        XCTAssertEqual(error as? OAuthError, .stateMismatch)
        XCTAssertTrue(stub.requests(to: Fixtures.tokenEndpoint).isEmpty, "the code must not be redeemed")
    }

    func test_completeAuthorizationRejectsTheWrongIssuer() async throws {
        stubHappyPath()
        let pending = try await client.beginAuthorization(account: Fixtures.handle)

        let error = await errorThrown {
            try await client.completeAuthorization(pending, callbackURL: callbackURL(state: pending.state, iss: "https://evil.example"))
        }

        XCTAssertEqual(error as? OAuthError, .issuerMismatch(expected: Fixtures.issuer.absoluteString, actual: "https://evil.example"))
        XCTAssertTrue(stub.requests(to: Fixtures.tokenEndpoint).isEmpty)
    }

    func test_completeAuthorizationSurfacesADeniedSignIn() async throws {
        stubHappyPath()
        let pending = try await client.beginAuthorization(account: Fixtures.handle)
        let denied = URL(string: "me.byjp.semble-share:/oauth/callback?state=\(pending.state)&error=access_denied&error_description=User%20said%20no")!

        let error = await errorThrown { try await client.completeAuthorization(pending, callbackURL: denied) }

        XCTAssertEqual(error as? OAuthError, .authorizationDenied(error: "access_denied", description: "User said no"))
    }

    func test_completeAuthorizationExchangesTheCodeWithTheMatchingVerifier() async throws {
        stubHappyPath()
        stub.on(Fixtures.tokenEndpoint, json: Fixtures.tokenResponse())
        let pending = try await client.beginAuthorization(account: Fixtures.handle)
        let parRequest = try XCTUnwrap(stub.requests(to: Fixtures.parEndpoint).last)
        let challengeSentAtPAR = try XCTUnwrap(formFields(of: parRequest)["code_challenge"])

        let before = Date()
        let session = try await client.completeAuthorization(pending, callbackURL: callbackURL(state: pending.state, code: "code-xyz"))

        let tokenRequest = try XCTUnwrap(stub.requests(to: Fixtures.tokenEndpoint).last)
        let fields = formFields(of: tokenRequest)
        XCTAssertEqual(fields["grant_type"], "authorization_code")
        XCTAssertEqual(fields["code"], "code-xyz")
        XCTAssertEqual(fields["client_id"], Fixtures.clientID.absoluteString)
        XCTAssertEqual(fields["redirect_uri"], Fixtures.redirectURI.absoluteString)
        let verifier = try XCTUnwrap(fields["code_verifier"])
        XCTAssertEqual(PKCE.challenge(for: verifier), challengeSentAtPAR, "the verifier must be the one whose hash was pushed")

        // Same DPoP key as PAR, so the tokens end up bound to the key we keep.
        let proof = try XCTUnwrap(DecodedProof(tokenRequest.headers["DPoP"]))
        let pendingKey = try P256.Signing.PrivateKey(rawRepresentation: pending.dpopPrivateKey)
        XCTAssertTrue(proof.isSigned(by: pendingKey.publicKey))

        XCTAssertEqual(session.did, Fixtures.did)
        XCTAssertEqual(session.handle, Fixtures.handle)
        XCTAssertEqual(session.pdsURL, Fixtures.pdsURL)
        XCTAssertEqual(session.authorizationServer, Fixtures.issuer)
        XCTAssertEqual(session.accessToken, "access-1")
        XCTAssertEqual(session.refreshToken, "refresh-1")
        XCTAssertEqual(session.scope, Fixtures.scope)
        XCTAssertEqual(session.dpopPrivateKey, pending.dpopPrivateKey)
        let expiresAt = try XCTUnwrap(session.expiresAt)
        XCTAssertGreaterThanOrEqual(expiresAt.timeIntervalSince(before), 3600 - 5)
        XCTAssertLessThanOrEqual(expiresAt.timeIntervalSince(before), 3600 + 5)
    }

    func test_completeAuthorizationRejectsATokenForAnotherAccount() async throws {
        stubHappyPath()
        stub.on(Fixtures.tokenEndpoint, json: Fixtures.tokenResponse(sub: "did:plc:somebodyelse"))
        let pending = try await client.beginAuthorization(account: Fixtures.handle)

        let error = await errorThrown {
            try await client.completeAuthorization(pending, callbackURL: callbackURL(state: pending.state))
        }

        XCTAssertEqual(error as? OAuthError, .subjectMismatch(expected: Fixtures.did, actual: "did:plc:somebodyelse"))
    }

    func test_completeAuthorizationRejectsABearerToken() async throws {
        stubHappyPath()
        stub.on(Fixtures.tokenEndpoint, json: #"{"access_token": "a", "refresh_token": "r", "token_type": "Bearer", "sub": "\#(Fixtures.did)"}"#)
        let pending = try await client.beginAuthorization(account: Fixtures.handle)

        let error = await errorThrown {
            try await client.completeAuthorization(pending, callbackURL: callbackURL(state: pending.state))
        }

        XCTAssertEqual(error as? OAuthError, .unsupportedTokenType("Bearer"))
    }

    func test_pendingAuthorizationSurvivesBeingPersisted() async throws {
        stubHappyPath()
        stub.on(Fixtures.tokenEndpoint, json: Fixtures.tokenResponse())
        let pending = try await client.beginAuthorization(account: Fixtures.handle)

        let data = try JSONEncoder().encode(pending)
        let restored = try JSONDecoder().decode(PendingAuthorization.self, from: data)

        XCTAssertEqual(restored.authorizationURL, pending.authorizationURL)
        XCTAssertEqual(restored.state, pending.state)
        XCTAssertEqual(restored.codeVerifier, pending.codeVerifier)
        XCTAssertEqual(restored.dpopPrivateKey, pending.dpopPrivateKey)
        XCTAssertEqual(restored.did, pending.did)
        let session = try await client.completeAuthorization(restored, callbackURL: callbackURL(state: restored.state))
        XCTAssertEqual(session.did, Fixtures.did)
    }

    // MARK: - refresh

    func test_refreshRotatesTheTokens() async throws {
        let key = P256.Signing.PrivateKey()
        let session = Fixtures.session(accessToken: "access-old", refreshToken: "refresh-old", privateKey: key)
        stub.stubOAuthDiscovery()
        stub.on(Fixtures.tokenEndpoint, json: Fixtures.tokenResponse(accessToken: "access-new", refreshToken: "refresh-new", expiresIn: 1800))

        let refreshed = try await client.refresh(session)

        let request = try XCTUnwrap(stub.requests(to: Fixtures.tokenEndpoint).last)
        let fields = formFields(of: request)
        XCTAssertEqual(fields["grant_type"], "refresh_token")
        XCTAssertEqual(fields["refresh_token"], "refresh-old")
        XCTAssertEqual(fields["client_id"], Fixtures.clientID.absoluteString)
        let proof = try XCTUnwrap(DecodedProof(request.headers["DPoP"]))
        XCTAssertTrue(proof.isSigned(by: key.publicKey), "signed with the session's own key")

        XCTAssertEqual(refreshed.accessToken, "access-new")
        XCTAssertEqual(refreshed.refreshToken, "refresh-new")
        XCTAssertEqual(refreshed.did, session.did)
        XCTAssertEqual(refreshed.handle, session.handle)
        XCTAssertEqual(refreshed.pdsURL, session.pdsURL)
        XCTAssertEqual(refreshed.dpopPrivateKey, session.dpopPrivateKey)
        XCTAssertNotEqual(refreshed.expiresAt, session.expiresAt)
    }

    func test_refreshIsRetriedOnceWithServerNonce() async throws {
        let session = Fixtures.session()
        stub.stubOAuthDiscovery()
        stub.on(Fixtures.tokenEndpoint) { request in
            guard DecodedProof(request.headers["DPoP"])?.nonce == "token-nonce" else {
                return Fixtures.useDPoPNonce("token-nonce")
            }
            return HTTPResponse(statusCode: 200, body: Data(Fixtures.tokenResponse().utf8))
        }

        let refreshed = try await client.refresh(session)

        XCTAssertEqual(stub.requests(to: Fixtures.tokenEndpoint).count, 2)
        XCTAssertEqual(refreshed.accessToken, "access-1")
    }

    func test_refreshMapsInvalidGrantToSessionExpired() async {
        stub.stubOAuthDiscovery()
        stub.on(Fixtures.tokenEndpoint, status: 400, json: #"{"error": "invalid_grant", "error_description": "Refresh token expired"}"#)

        let error = await errorThrown { try await client.refresh(Fixtures.session()) }

        XCTAssertEqual(error as? OAuthError, .sessionExpired)
        XCTAssertEqual(error?.localizedDescription, "Your sign-in has expired. Please sign in to Semble again.")
    }

    func test_refreshRejectsATokenForAnotherAccount() async {
        stub.stubOAuthDiscovery()
        stub.on(Fixtures.tokenEndpoint, json: Fixtures.tokenResponse(sub: "did:plc:somebodyelse"))

        let error = await errorThrown { try await client.refresh(Fixtures.session()) }

        XCTAssertEqual(error as? OAuthError, .subjectMismatch(expected: Fixtures.did, actual: "did:plc:somebodyelse"))
    }
}
