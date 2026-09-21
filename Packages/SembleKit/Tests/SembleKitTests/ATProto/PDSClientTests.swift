import CryptoKit
import OAuthenticator
import XCTest
@testable import SembleKit

final class PDSClientTests: XCTestCase {
    private struct TestRecord: Codable, Equatable {
        var type = "app.example.record"
        var text: String

        enum CodingKeys: String, CodingKey {
            case type = "$type"
            case text
        }
    }

    private static let createRecord = "https://pds.example/xrpc/com.atproto.repo.createRecord"
    private static let listRecords = "https://pds.example/xrpc/com.atproto.repo.listRecords"
    private static let getRecord = "https://pds.example/xrpc/com.atproto.repo.getRecord"
    private static let deleteRecord = "https://pds.example/xrpc/com.atproto.repo.deleteRecord"
    private static let strongRefJSON = #"{"uri": "at://did:plc:abc123xyz/app.example.record/3kabc", "cid": "bafyreic", "commit": {"cid": "bafycommit", "rev": "3kabd"}}"#

    private var stub: StubHTTPClient!
    private var store: InMemorySessionStore!
    private var key: DPoPKey!

    override func setUp() {
        super.setUp()
        stub = StubHTTPClient()
        store = InMemorySessionStore()
        key = DPoPKey.P256()
    }

    private func makeClient(session: Session) -> PDSClient {
        _ = try? store.save(session)
        return PDSClient(session: session, sessionStore: store, configuration: Fixtures.configuration, http: stub)
    }

    private func session(expiry: Date? = Date().addingTimeInterval(3600)) -> Session {
        Fixtures.session(accessToken: "access-0", refreshToken: "refresh-0", expiry: expiry, key: key)
    }

    /// Stubs a refresh that hands out `access-1` / `refresh-1`.
    private func stubRefresh() {
        stub.on(Fixtures.tokenEndpoint, json: Fixtures.tokenResponse(accessToken: "access-1", refreshToken: "refresh-1"))
    }

    private func authorization(of request: HTTPRequest) -> String? {
        request.headers["Authorization"]
    }

    // MARK: - Headers

    func test_requestsCarryADPoPBoundAuthorization() async throws {
        stub.on(Self.createRecord, json: Self.strongRefJSON)
        let client = makeClient(session: session())

        _ = try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hi"))

        let request = try XCTUnwrap(stub.requests(to: Self.createRecord).last)
        XCTAssertEqual(authorization(of: request), "DPoP access-0")
        XCTAssertEqual(request.headers["Accept"], "application/json")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let proof = try XCTUnwrap(DecodedProof(request.headers["DPoP"]))
        XCTAssertEqual(proof.payload["htm"] as? String, "POST")
        XCTAssertEqual(proof.payload["htu"] as? String, Self.createRecord)
        XCTAssertEqual(proof.payload["ath"] as? String, sha256URL("access-0"))
        XCTAssertTrue(proof.isSigned(by: try key.p256PrivateKey.publicKey))
    }

    // MARK: - Nonces

    func test_retriesOnceWithTheServersNonce() async throws {
        stub.on(Self.createRecord) { request in
            guard DecodedProof(request.headers["DPoP"])?.nonce == "pds-nonce" else {
                return HTTPResponse(
                    statusCode: 401,
                    headers: ["DPoP-Nonce": "pds-nonce", "WWW-Authenticate": #"DPoP error="use_dpop_nonce""#],
                    body: Data(#"{"error": "use_dpop_nonce", "message": "DPoP nonce mismatch"}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 200, body: Data(Self.strongRefJSON.utf8))
        }
        let client = makeClient(session: session())

        _ = try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hi"))

        let requests = stub.requests(to: Self.createRecord)
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(DecodedProof(requests[0].headers["DPoP"])?.nonce)
        XCTAssertEqual(DecodedProof(requests[1].headers["DPoP"])?.nonce, "pds-nonce")
    }

    func test_doesNotLoopWhenTheServerKeepsAskingForANonce() async {
        stub.on(Self.createRecord) { _ in
            HTTPResponse(
                statusCode: 401,
                headers: ["DPoP-Nonce": "always-new-\(UUID().uuidString)", "WWW-Authenticate": #"DPoP error="use_dpop_nonce""#],
                body: Data(#"{"error": "use_dpop_nonce"}"#.utf8)
            )
        }
        stubRefresh()
        let client = makeClient(session: session())

        let error = await errorThrown { try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hi")) }
        XCTAssertNotNil(error)
        XCTAssertLessThanOrEqual(stub.requests(to: Self.createRecord).count, 4)
    }

    // MARK: - Token refresh

    func test_refreshesAnExpiredSessionAndPersistsItBeforeCalling() async throws {
        stubRefresh()
        stub.on(Self.createRecord, json: Self.strongRefJSON)
        let client = makeClient(session: session(expiry: Date().addingTimeInterval(-60)))

        _ = try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hi"))

        let refresh = try XCTUnwrap(stub.requests(to: Fixtures.tokenEndpoint).last)
        XCTAssertEqual(jsonFields(of: refresh)["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(jsonFields(of: refresh)["refresh_token"] as? String, "refresh-0")
        XCTAssertTrue(try XCTUnwrap(DecodedProof(refresh.headers["DPoP"])).isSigned(by: try key.p256PrivateKey.publicKey))

        let call = try XCTUnwrap(stub.requests(to: Self.createRecord).last)
        XCTAssertEqual(authorization(of: call), "DPoP access-1")

        let saved = try XCTUnwrap(try store.load())
        XCTAssertEqual(saved.login.accessToken.value, "access-1")
        XCTAssertEqual(saved.login.refreshToken?.value, "refresh-1")
        XCTAssertEqual(saved.dpopKey, key, "a refresh keeps the key the tokens are bound to")
        let current = await client.currentSession
        XCTAssertEqual(current.login.accessToken.value, "access-1")
    }

    func test_refreshesWhenThePDSRejectsTheTokenAndRetriesOnce() async throws {
        stub.on(Self.createRecord) { request in
            guard request.headers["Authorization"] == "DPoP access-1" else {
                return HTTPResponse(
                    statusCode: 401,
                    headers: ["WWW-Authenticate": #"DPoP error="invalid_token""#],
                    body: Data(#"{"error": "invalid_token", "message": "Token has expired"}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 200, body: Data(Self.strongRefJSON.utf8))
        }
        stubRefresh()
        let client = makeClient(session: session())

        _ = try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hi"))

        XCTAssertEqual(stub.requests(to: Self.createRecord).count, 2)
        XCTAssertEqual(stub.requests(to: Fixtures.tokenEndpoint).count, 1)
        XCTAssertEqual(try store.load()?.login.refreshToken?.value, "refresh-1")
    }

    func test_aDeadRefreshTokenSurfacesAsSessionExpiredAndForgetsTheSession() async {
        stub.on(Fixtures.tokenEndpoint, status: 400, json: #"{"error": "invalid_grant", "error_description": "Refresh token expired"}"#)
        let client = makeClient(session: session(expiry: Date().addingTimeInterval(-60)))

        let error = await errorThrown { try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hi")) }
        XCTAssertEqual(error as? OAuthError, .sessionExpired)
        XCTAssertNil(try? store.load(), "a session the server has rejected must not linger in the store")
        XCTAssertTrue(stub.requests(to: Self.createRecord).isEmpty)
    }

    func test_aDroppedConnectionDuringRefreshKeepsTheSession() async {
        stub.on(Fixtures.tokenEndpoint) { _ in throw URLError(.notConnectedToInternet) }
        let client = makeClient(session: session(expiry: Date().addingTimeInterval(-60)))

        let error = await errorThrown { try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hi")) }
        XCTAssertNotNil(error)
        XCTAssertNotNil(try? store.load(), "being offline is not a reason to log the user out")
    }

    // MARK: - Shared Keychain item (app + extension)

    func test_aSessionRotatedInTheStoreByAnotherProcessIsPickedUpRatherThanTheStaleInMemoryOne() async throws {
        stub.on(Self.createRecord, json: Self.strongRefJSON)
        let client = makeClient(session: session())
        // Another process (the app, or another extension instance) refreshed
        // and saved a newer session while this client still has the
        // original in memory.
        try store.save(Fixtures.session(accessToken: "access-9", refreshToken: "refresh-9", key: key))

        _ = try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hi"))

        let request = try XCTUnwrap(stub.requests(to: Self.createRecord).last)
        XCTAssertEqual(authorization(of: request), "DPoP access-9")
    }

    func test_anInvalidGrantForAStaleTokenLeavesANewerStoredSessionIntact() async {
        let store = self.store!
        let newer = Fixtures.session(accessToken: "access-9", refreshToken: "refresh-9", key: key)
        stub.on(Fixtures.tokenEndpoint) { _ in
            // Another process rotates the session mid-flight: the refresh
            // token this request carries (refresh-0) is now stale, and the
            // server correctly rejects it.
            try store.save(newer)
            return HTTPResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error": "invalid_grant", "error_description": "Refresh token expired"}"#.utf8)
            )
        }
        let client = makeClient(session: session(expiry: Date().addingTimeInterval(-60)))

        let error = await errorThrown { try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hi")) }
        XCTAssertEqual(error as? OAuthError, .sessionExpired)
        XCTAssertEqual((try? store.load())?.login.refreshToken?.value, "refresh-9", "the newer session saved by another process must survive a stale rejection")
    }

    // An invalid_grant for the CURRENT (not stale) refresh token still
    // clears the store: see `test_aDeadRefreshTokenSurfacesAsSessionExpiredAndForgetsTheSession` above.

    // MARK: - Records

    func test_createRecordSendsTheRecordAndReturnsItsStrongRef() async throws {
        stub.on(Self.createRecord, json: Self.strongRefJSON)
        let client = makeClient(session: session())

        let ref = try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hello"))

        XCTAssertEqual(ref, StrongRef(uri: "at://did:plc:abc123xyz/app.example.record/3kabc", cid: "bafyreic"))
        let body = jsonFields(of: try XCTUnwrap(stub.requests(to: Self.createRecord).last))
        XCTAssertEqual(body["repo"] as? String, Fixtures.did)
        XCTAssertEqual(body["collection"] as? String, "app.example.record")
        XCTAssertEqual((body["record"] as? [String: Any])?["text"] as? String, "hello")
        XCTAssertEqual((body["record"] as? [String: Any])?["$type"] as? String, "app.example.record")
    }

    func test_listRecordsDecodesRecordsAndCursor() async throws {
        stub.on(Self.listRecords, json: """
        {"records": [
           {"uri": "at://did:plc:abc123xyz/app.example.record/1", "cid": "c1", "value": {"$type": "app.example.record", "text": "one"}},
           {"uri": "at://did:plc:abc123xyz/app.example.record/2", "cid": "c2", "value": {"$type": "app.example.record", "text": "two"}}
         ], "cursor": "next"}
        """)
        let client = makeClient(session: session())

        let page: RecordPage<TestRecord> = try await client.listRecords(collection: "app.example.record", limit: 50, cursor: "prev")

        XCTAssertEqual(page.records.map(\.value.text), ["one", "two"])
        XCTAssertEqual(page.records.first?.ref, StrongRef(uri: "at://did:plc:abc123xyz/app.example.record/1", cid: "c1"))
        XCTAssertEqual(page.cursor, "next")
        let request = try XCTUnwrap(stub.requests(to: Self.listRecords).last)
        XCTAssertEqual(request.method, "GET")
        let query = queryParameters(of: request.url)
        XCTAssertEqual(query["repo"], Fixtures.did)
        XCTAssertEqual(query["collection"], "app.example.record")
        XCTAssertEqual(query["limit"], "50")
        XCTAssertEqual(query["cursor"], "prev")
        XCTAssertEqual(DecodedProof(request.headers["DPoP"])?.payload["htu"] as? String, Self.listRecords, "htu excludes the query string")
    }

    func test_listRecordsWithoutACursorHasNoCursorParameter() async throws {
        stub.on(Self.listRecords, json: #"{"records": []}"#)
        let client = makeClient(session: session())

        let page: RecordPage<TestRecord> = try await client.listRecords(collection: "app.example.record")

        XCTAssertTrue(page.records.isEmpty)
        XCTAssertNil(page.cursor)
        let query = queryParameters(of: try XCTUnwrap(stub.requests(to: Self.listRecords).last).url)
        XCTAssertNil(query["cursor"])
        XCTAssertEqual(query["limit"], "100")
    }

    func test_getRecordDecodesTheEnvelope() async throws {
        stub.on(Self.getRecord, json: #"{"uri": "at://did:plc:abc123xyz/app.example.record/3kabc", "cid": "c9", "value": {"$type": "app.example.record", "text": "found"}}"#)
        let client = makeClient(session: session())

        let envelope: RecordEnvelope<TestRecord> = try await client.getRecord(collection: "app.example.record", rkey: "3kabc")

        XCTAssertEqual(envelope.value.text, "found")
        XCTAssertEqual(queryParameters(of: try XCTUnwrap(stub.requests(to: Self.getRecord).last).url)["rkey"], "3kabc")
    }

    func test_deleteRecordPostsTheKey() async throws {
        stub.on(Self.deleteRecord, json: "{}")
        let client = makeClient(session: session())

        try await client.deleteRecord(collection: "app.example.record", rkey: "3kabc")

        let body = jsonFields(of: try XCTUnwrap(stub.requests(to: Self.deleteRecord).last))
        XCTAssertEqual(body["rkey"] as? String, "3kabc")
        XCTAssertEqual(body["collection"] as? String, "app.example.record")
    }

    // MARK: - Errors

    func test_serverErrorsCarryThePDSMessage() async {
        stub.on(Self.createRecord, status: 400, json: #"{"error": "InvalidRecord", "message": "Record/content must be an object"}"#)
        let client = makeClient(session: session())

        let error = await errorThrown { try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "x")) }
        XCTAssertEqual(error as? XRPCError, .server(status: 400, error: "InvalidRecord", message: "Record/content must be an object"))
        XCTAssertEqual(error?.localizedDescription, "Record/content must be an object")
    }

    func test_serverErrorsWithoutAMessageStillReadWell() async {
        stub.on(Self.createRecord) { _ in HTTPResponse(statusCode: 503, body: Data("<html>upstream down</html>".utf8)) }
        let client = makeClient(session: session())

        let error = await errorThrown { try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "x")) }
        XCTAssertEqual(error?.localizedDescription, "Your data server is having problems right now. Try again in a moment.")
    }

    func test_didIsTheSessionsDID() async {
        let client = makeClient(session: session())
        let did = await client.did
        XCTAssertEqual(did, Fixtures.did)
    }
}
