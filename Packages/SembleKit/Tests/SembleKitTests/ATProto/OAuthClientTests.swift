import OAuthenticator
import XCTest
@testable import SembleKit

/// Sign-in end to end against a stubbed identity, PDS and authorization
/// server. OAuthenticator does the OAuth mechanics; these tests pin down what
/// we add around it and that the pieces are wired together correctly.
final class OAuthClientTests: XCTestCase {
    private var stub: StubHTTPClient!

    override func setUp() {
        super.setUp()
        stub = StubHTTPClient()
    }

    private func makeClient() -> OAuthClient {
        OAuthClient(configuration: Fixtures.configuration, http: stub)
    }

    /// Everything a successful sign-in needs, ready for the browser step.
    private func stubHappyPath() {
        stub.stubIdentity()
        stub.stubOAuthDiscovery()
        stub.stubPAR()
        stub.on(Fixtures.tokenEndpoint, json: Fixtures.tokenResponse())
    }

    /// The `state` OAuthenticator pushed, read back from the PAR request so
    /// the fake browser can echo it.
    private func pushedState() -> String? {
        stub.requests(to: Fixtures.parEndpoint).last.flatMap { formFields(of: $0)["state"] }
    }

    /// A browser that approves the sign-in and comes back through the redirect URI.
    private func approvingBrowser(state: (() -> String?)? = nil, issuer: String = Fixtures.issuer.absoluteString) -> Authenticator.UserAuthenticator {
        let stub = self.stub!
        return { _, _ in
            let state = state?() ?? stub.requests(to: Fixtures.parEndpoint).last.flatMap { formFields(of: $0)["state"] } ?? ""
            var components = URLComponents(url: Fixtures.redirectURI, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "code", value: "code-1"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "iss", value: issuer),
            ]
            return components.url!
        }
    }

    // MARK: - Happy path

    func test_signInPushesTheRequestThenOpensTheBrowserWithIt() async throws {
        stubHappyPath()
        var opened: (URL, String)?
        let browser = approvingBrowser()
        let session = try await makeClient().signIn(account: "@Alice.example.com ") { url, scheme in
            opened = (url, scheme)
            return try await browser(url, scheme)
        }

        let par = try XCTUnwrap(stub.requests(to: Fixtures.parEndpoint).last)
        let fields = formFields(of: par)
        XCTAssertEqual(fields["client_id"], Fixtures.clientID.absoluteString)
        XCTAssertEqual(fields["redirect_uri"], Fixtures.redirectURI.absoluteString)
        XCTAssertEqual(fields["scope"], Fixtures.scope)
        XCTAssertEqual(fields["code_challenge_method"], "S256")
        XCTAssertEqual(fields["login_hint"], Fixtures.handle)
        XCTAssertNotNil(DecodedProof(par.headers["DPoP"]), "PAR must carry a DPoP proof")

        let (url, scheme) = try XCTUnwrap(opened)
        XCTAssertTrue(url.absoluteString.hasPrefix(Fixtures.authorizeEndpoint))
        XCTAssertEqual(queryParameters(of: url)["request_uri"], "urn:ietf:params:oauth:request_uri:abc")
        XCTAssertEqual(queryParameters(of: url)["client_id"], Fixtures.clientID.absoluteString)
        XCTAssertEqual(scheme, "me.byjp.semble-share")

        XCTAssertEqual(session.did, Fixtures.did)
        XCTAssertEqual(session.handle, Fixtures.handle)
        XCTAssertEqual(session.pdsURL, Fixtures.pdsURL)
        XCTAssertEqual(session.authorizationServer.issuer, Fixtures.issuer.absoluteString)
        XCTAssertEqual(session.login.accessToken.value, "access-1")
        XCTAssertEqual(session.login.refreshToken?.value, "refresh-1")
    }

    func test_signInExchangesTheCodeWithTheVerifierForThePushedChallenge() async throws {
        stubHappyPath()
        _ = try await makeClient().signIn(account: Fixtures.handle, openBrowser: approvingBrowser())

        let challenge = try XCTUnwrap(formFields(of: XCTUnwrap(stub.requests(to: Fixtures.parEndpoint).last))["code_challenge"])
        let token = try XCTUnwrap(stub.requests(to: Fixtures.tokenEndpoint).last)
        let body = jsonFields(of: token)
        XCTAssertEqual(body["grant_type"] as? String, "authorization_code")
        XCTAssertEqual(body["code"] as? String, "code-1")
        XCTAssertEqual(body["redirect_uri"] as? String, Fixtures.redirectURI.absoluteString)
        let verifier = try XCTUnwrap(body["code_verifier"] as? String)
        XCTAssertEqual(sha256URL(verifier), challenge)

        // The token request is bound to the same key the PAR was.
        let parKey = DecodedProof(stub.requests(to: Fixtures.parEndpoint).last?.headers["DPoP"])?.advertisedPublicKey()
        let tokenKey = DecodedProof(token.headers["DPoP"])?.advertisedPublicKey()
        XCTAssertNotNil(parKey)
        XCTAssertEqual(parKey?.rawRepresentation, tokenKey?.rawRepresentation)
    }

    func test_sessionCarriesTheKeyTheTokensAreBoundTo() async throws {
        stubHappyPath()
        let session = try await makeClient().signIn(account: Fixtures.handle, openBrowser: approvingBrowser())

        let tokenKey = DecodedProof(stub.requests(to: Fixtures.tokenEndpoint).last?.headers["DPoP"])?.advertisedPublicKey()
        XCTAssertEqual(try session.dpopKey.p256PrivateKey.publicKey.rawRepresentation, tokenKey?.rawRepresentation)
    }

    // MARK: - Nonces

    func test_parIsRetriedOnceWithServerNonce() async throws {
        stub.stubIdentity()
        stub.stubOAuthDiscovery()
        stub.on(Fixtures.parEndpoint) { request in
            guard DecodedProof(request.headers["DPoP"])?.nonce == "auth-nonce" else {
                return Fixtures.useDPoPNonce("auth-nonce")
            }
            return HTTPResponse(statusCode: 201, body: Data(#"{"request_uri": "urn:ietf:params:oauth:request_uri:abc", "expires_in": 60}"#.utf8))
        }
        stub.on(Fixtures.tokenEndpoint, json: Fixtures.tokenResponse())

        _ = try await makeClient().signIn(account: Fixtures.handle, openBrowser: approvingBrowser())

        let pars = stub.requests(to: Fixtures.parEndpoint)
        XCTAssertEqual(pars.count, 2)
        XCTAssertNil(DecodedProof(pars[0].headers["DPoP"])?.nonce)
        XCTAssertEqual(DecodedProof(pars[1].headers["DPoP"])?.nonce, "auth-nonce")
    }

    // MARK: - Rejections

    func test_rejectsATokenForAnotherAccount() async {
        stub.stubIdentity()
        stub.stubOAuthDiscovery()
        stub.stubPAR()
        stub.on(Fixtures.tokenEndpoint, json: Fixtures.tokenResponse(sub: "did:plc:someoneelse"))

        let error = await errorThrown { try await makeClient().signIn(account: Fixtures.handle, openBrowser: approvingBrowser()) }
        XCTAssertEqual(error as? OAuthError, .subjectMismatch)
    }

    func test_rejectsACallbackWithTheWrongState() async {
        stubHappyPath()
        let error = await errorThrown {
            try await makeClient().signIn(account: Fixtures.handle, openBrowser: approvingBrowser(state: { "forged" }))
        }
        XCTAssertEqual(error as? OAuthError, .callbackRejected)
        XCTAssertTrue(stub.requests(to: Fixtures.tokenEndpoint).isEmpty, "a forged callback must never reach the token endpoint")
    }

    func test_rejectsACallbackFromAnotherIssuer() async {
        stubHappyPath()
        let error = await errorThrown {
            try await makeClient().signIn(account: Fixtures.handle, openBrowser: approvingBrowser(issuer: "https://evil.example"))
        }
        XCTAssertEqual(error as? OAuthError, .callbackRejected)
    }

    func test_rejectsMetadataFromAnotherIssuer() async {
        stub.stubIdentity()
        stub.stubOAuthDiscovery(metadataIssuer: URL(string: "https://other.example")!)
        let error = await errorThrown { try await makeClient().signIn(account: Fixtures.handle, openBrowser: approvingBrowser()) }
        XCTAssertEqual(error as? OAuthError, .issuerMismatch)
    }

    func test_surfacesTheServersRefusal() async {
        stub.stubIdentity()
        stub.stubOAuthDiscovery()
        stub.on(Fixtures.parEndpoint, status: 400, json: #"{"error": "invalid_scope", "error_description": "Unknown scope include:network.cosmik.authFull"}"#)
        let error = await errorThrown { try await makeClient().signIn(account: Fixtures.handle, openBrowser: approvingBrowser()) }
        XCTAssertEqual(error as? OAuthError, .authorizationServerRejected("Unknown scope include:network.cosmik.authFull"))
    }

    func test_aCancelledBrowserIsPassedThroughUntouched() async {
        struct Cancelled: Error {}
        stubHappyPath()
        let error = await errorThrown {
            try await makeClient().signIn(account: Fixtures.handle) { _, _ in throw Cancelled() }
        }
        XCTAssertTrue(error is Cancelled)
    }

    func test_errorsReadLikeSentences() {
        XCTAssertEqual(OAuthError.sessionExpired.localizedDescription, "Your Semble sign-in has expired. Open the Add to Semble app and log in again.")
        XCTAssertEqual(OAuthError.discoveryFailed("pds.example").localizedDescription, "Couldn't find the sign-in settings for pds.example.")
    }
}
