import CryptoKit
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
    private var key: P256.Signing.PrivateKey!

    override func setUp() {
        super.setUp()
        stub = StubHTTPClient()
        store = InMemorySessionStore()
        key = P256.Signing.PrivateKey()
    }

    private func makeClient(session: Session) -> PDSClient {
        _ = try? store.save(session)
        let oauth = OAuthClient(configuration: Fixtures.configuration, http: stub)
        return PDSClient(session: session, sessionStore: store, oauth: oauth, http: stub)
    }

    private func session(expiresAt: Date? = Date().addingTimeInterval(3600)) -> Session {
        Fixtures.session(accessToken: "access-0", refreshToken: "refresh-0", expiresAt: expiresAt, privateKey: key)
    }

    /// Stubs a refresh that hands out `access-1` / `refresh-1`.
    private func stubRefresh() {
        stub.stubOAuthDiscovery()
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
        XCTAssertEqual(proof.payload["ath"] as? String, Data(SHA256.hash(data: Data("access-0".utf8))).base64URLEncodedString())
        XCTAssertTrue(proof.isSigned(by: key.publicKey))
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
            return HTTPResponse(statusCode: 200, headers: ["DPoP-Nonce": "pds-nonce"], body: Data(Self.strongRefJSON.utf8))
        }
        let client = makeClient(session: session())

        _ = try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hi"))

        let requests = stub.requests(to: Self.createRecord)
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(DecodedProof(requests[0].headers["DPoP"])?.nonce)
        XCTAssertEqual(DecodedProof(requests[1].headers["DPoP"])?.nonce, "pds-nonce")

        // The nonce is remembered: the next call carries it from the start.
        _ = try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "again"))
        XCTAssertEqual(stub.requests(to: Self.createRecord).count, 3)
        XCTAssertEqual(DecodedProof(stub.lastRequest?.headers["DPoP"])?.nonce, "pds-nonce")
    }

    func test_doesNotLoopWhenTheServerKeepsAskingForANonce() async {
        stub.on(Self.createRecord) { _ in
            HTTPResponse(statusCode: 401, headers: ["DPoP-Nonce": "another"], body: Data(#"{"error": "use_dpop_nonce"}"#.utf8))
        }
        let client = makeClient(session: session())

        let error = await errorThrown { try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hi")) }

        XCTAssertEqual(stub.requests(to: Self.createRecord).count, 2)
        XCTAssertEqual(error as? XRPCError, .server(status: 401, error: "use_dpop_nonce", message: nil))
    }

    // MARK: - Token refresh

    func test_refreshesAnExpiredSessionAndPersistsItBeforeCalling() async throws {
        stubRefresh()
        stub.on(Self.createRecord) { request in
            guard request.headers["Authorization"] == "DPoP access-1" else {
                return HTTPResponse(statusCode: 401, body: Data(#"{"error": "ExpiredToken"}"#.utf8))
            }
            return HTTPResponse(statusCode: 200, body: Data(Self.strongRefJSON.utf8))
        }
        let client = makeClient(session: session(expiresAt: Date().addingTimeInterval(-60)))

        _ = try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hi"))

        XCTAssertEqual(stub.requests(to: Fixtures.tokenEndpoint).count, 1)
        XCTAssertEqual(stub.requests(to: Self.createRecord).count, 1, "refreshed before the first attempt, not after a rejection")
        XCTAssertEqual(try store.load()?.accessToken, "access-1")
        XCTAssertEqual(try store.load()?.refreshToken, "refresh-1")
        let current = await client.currentSession
        XCTAssertEqual(current.accessToken, "access-1")
    }

    func test_refreshesWhenThePDSRejectsTheTokenAndRetriesOnce() async throws {
        stubRefresh()
        stub.on(Self.createRecord) { request in
            guard request.headers["Authorization"] == "DPoP access-1" else {
                return HTTPResponse(statusCode: 401, body: Data(#"{"error": "invalid_token", "message": "Token has expired"}"#.utf8))
            }
            return HTTPResponse(statusCode: 200, body: Data(Self.strongRefJSON.utf8))
        }
        let client = makeClient(session: session())

        let ref = try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hi"))

        XCTAssertEqual(ref.cid, "bafyreic")
        let requests = stub.requests(to: Self.createRecord)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(authorization(of: requests[0]), "DPoP access-0")
        XCTAssertEqual(authorization(of: requests[1]), "DPoP access-1")
        XCTAssertEqual(try store.load()?.refreshToken, "refresh-1", "the rotated refresh token is persisted")
    }

    func test_doesNotLoopWhenTheTokenKeepsBeingRejected() async {
        stubRefresh()
        stub.on(Self.createRecord, status: 401, json: #"{"error": "invalid_token", "message": "Nope"}"#)
        let client = makeClient(session: session())

        let error = await errorThrown { try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hi")) }

        XCTAssertEqual(stub.requests(to: Self.createRecord).count, 2)
        XCTAssertEqual(stub.requests(to: Fixtures.tokenEndpoint).count, 1)
        XCTAssertEqual(error as? XRPCError, .server(status: 401, error: "invalid_token", message: "Nope"))
    }

    func test_aDeadRefreshTokenSurfacesAsSessionExpired() async {
        stub.stubOAuthDiscovery()
        stub.on(Fixtures.tokenEndpoint, status: 400, json: #"{"error": "invalid_grant"}"#)
        let client = makeClient(session: session(expiresAt: Date().addingTimeInterval(-60)))

        let error = await errorThrown { try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hi")) }

        XCTAssertEqual(error as? OAuthError, .sessionExpired)
        XCTAssertTrue(stub.requests(to: Self.createRecord).isEmpty)
    }

    // MARK: - Records

    func test_createRecordSendsTheRecordAndReturnsItsStrongRef() async throws {
        stub.on(Self.createRecord, json: Self.strongRefJSON)
        let client = makeClient(session: session())

        let ref = try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hello"))

        XCTAssertEqual(ref, StrongRef(uri: "at://did:plc:abc123xyz/app.example.record/3kabc", cid: "bafyreic"))
        let request = try XCTUnwrap(stub.requests(to: Self.createRecord).last)
        let bodyData = try XCTUnwrap(request.body)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["repo"] as? String, Fixtures.did)
        XCTAssertEqual(body["collection"] as? String, "app.example.record")
        let record = try XCTUnwrap(body["record"] as? [String: Any])
        XCTAssertEqual(record["$type"] as? String, "app.example.record")
        XCTAssertEqual(record["text"] as? String, "hello")
    }

    func test_listRecordsDecodesRecordsAndCursor() async throws {
        stub.on(Self.listRecords, json: """
        {
          "records": [
            {"uri": "at://did:plc:abc123xyz/app.example.record/1", "cid": "cid1", "value": {"$type": "app.example.record", "text": "one"}},
            {"uri": "at://did:plc:abc123xyz/app.example.record/2", "cid": "cid2", "value": {"$type": "app.example.record", "text": "two"}}
          ],
          "cursor": "next-page"
        }
        """)
        let client = makeClient(session: session())

        let page: RecordPage<TestRecord> = try await client.listRecords(collection: "app.example.record", limit: 50, cursor: "prev-page")

        XCTAssertEqual(page.cursor, "next-page")
        XCTAssertEqual(page.records.map(\.value.text), ["one", "two"])
        XCTAssertEqual(page.records.first?.ref, StrongRef(uri: "at://did:plc:abc123xyz/app.example.record/1", cid: "cid1"))

        let request = try XCTUnwrap(stub.requests(to: Self.listRecords).last)
        XCTAssertEqual(request.method, "GET")
        XCTAssertNil(request.body)
        let query = queryParameters(of: request.url)
        XCTAssertEqual(query["repo"], Fixtures.did)
        XCTAssertEqual(query["collection"], "app.example.record")
        XCTAssertEqual(query["limit"], "50")
        XCTAssertEqual(query["cursor"], "prev-page")
        XCTAssertEqual(DecodedProof(request.headers["DPoP"])?.payload["htm"] as? String, "GET")
        XCTAssertEqual(DecodedProof(request.headers["DPoP"])?.payload["htu"] as? String, Self.listRecords, "query is not part of htu")
    }

    func test_listRecordsWithoutACursorHasNoCursorParameter() async throws {
        stub.on(Self.listRecords, json: #"{"records": []}"#)
        let client = makeClient(session: session())

        let page: RecordPage<TestRecord> = try await client.listRecords(collection: "app.example.record")

        XCTAssertTrue(page.records.isEmpty)
        XCTAssertNil(page.cursor)
        let request = try XCTUnwrap(stub.requests(to: Self.listRecords).last)
        XCTAssertNil(queryParameters(of: request.url)["cursor"])
        XCTAssertEqual(queryParameters(of: request.url)["limit"], "100")
    }

    func test_getRecordDecodesTheEnvelope() async throws {
        stub.on(Self.getRecord, json: #"{"uri": "at://did:plc:abc123xyz/app.example.record/1", "cid": "cid1", "value": {"$type": "app.example.record", "text": "one"}}"#)
        let client = makeClient(session: session())

        let envelope: RecordEnvelope<TestRecord> = try await client.getRecord(collection: "app.example.record", rkey: "1")

        XCTAssertEqual(envelope.value, TestRecord(text: "one"))
        XCTAssertEqual(envelope.cid, "cid1")
        let request = try XCTUnwrap(stub.requests(to: Self.getRecord).last)
        XCTAssertEqual(queryParameters(of: request.url)["rkey"], "1")
    }

    func test_deleteRecordPostsTheKey() async throws {
        stub.on(Self.deleteRecord, json: #"{"commit": {"cid": "c", "rev": "r"}}"#)
        let client = makeClient(session: session())

        try await client.deleteRecord(collection: "app.example.record", rkey: "3kabc")

        let request = try XCTUnwrap(stub.requests(to: Self.deleteRecord).last)
        let bodyData = try XCTUnwrap(request.body)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["repo"] as? String, Fixtures.did)
        XCTAssertEqual(body["collection"] as? String, "app.example.record")
        XCTAssertEqual(body["rkey"] as? String, "3kabc")
    }

    // MARK: - Errors

    func test_serverErrorsCarryThePDSMessage() async {
        stub.on(Self.createRecord, status: 400, json: #"{"error": "InvalidRecord", "message": "Record/text must be a string"}"#)
        let client = makeClient(session: session())

        let error = await errorThrown { try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hi")) }

        XCTAssertEqual(error as? XRPCError, .server(status: 400, error: "InvalidRecord", message: "Record/text must be a string"))
        XCTAssertEqual(error?.localizedDescription, "Record/text must be a string")
    }

    func test_serverErrorsWithoutAMessageStillReadWell() async {
        stub.on(Self.createRecord) { _ in HTTPResponse(statusCode: 503, body: Data("<html>bad gateway</html>".utf8)) }
        let client = makeClient(session: session())

        let error = await errorThrown { try await client.createRecord(collection: "app.example.record", record: TestRecord(text: "hi")) }

        XCTAssertEqual(error as? XRPCError, .server(status: 503, error: nil, message: nil))
        XCTAssertEqual(error?.localizedDescription, "Your data server is having problems right now. Try again in a moment.")
    }

    func test_didIsTheSessionsDID() async {
        let client = makeClient(session: session())

        let did = await client.did

        XCTAssertEqual(did, Fixtures.did)
    }
}
