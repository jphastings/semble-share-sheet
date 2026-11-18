import Foundation
import XCTest
@testable import SembleKit

final class SharedCollectionsClientTests: XCTestCase {
    private let api = "https://api.semble.so/xrpc/"
    private let bobsLinks = "at://did:plc:bob/network.cosmik.collection/links"

    func testContributedCollectionsAreListedForTheUsersDIDWithoutAuth() async throws {
        let http = StubHTTPClient()
        http.on(api + "network.cosmik.collection.listContributed", json: SharedFixtures.page([
            (uri: bobsLinks, name: "Links", handle: "bob.test"),
        ]))

        let found = try await SharedCollectionsClient(http: http).contributed(by: "did:plc:alice")

        XCTAssertEqual(found, [CollectionSummary(sharedURI: bobsLinks, name: "Links", accessType: .open, ownerHandle: "bob.test")])
        let request = try XCTUnwrap(http.lastRequest)
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertEqual(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "identifier" }?.value, "did:plc:alice")
    }

    func testSearchAsksForOpenCollectionsMatchingTheText() async throws {
        let http = StubHTTPClient()
        http.on(api + "network.cosmik.collection.search", json: SharedFixtures.page([]))

        _ = try await SharedCollectionsClient(http: http).search("cats & dogs")

        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(http.lastRequest).url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "searchText" }?.value, "cats & dogs")
        XCTAssertEqual(query.first { $0.name == "accessType" }?.value, "OPEN")
    }

    func testItemsThatCannotBeLinkedAreSkipped() async throws {
        let http = StubHTTPClient()
        http.on(api + "network.cosmik.collection.search", json: """
        {"collections": [
          {"id": "1", "name": "Unpublished", "author": {"id": "did:plc:bob", "handle": "bob.test"}},
          {"id": "2", "uri": "at://did:plc:bob/network.cosmik.card/x", "name": "Not a collection", "author": {"id": "did:plc:bob", "handle": "bob.test"}},
          {"id": "3", "uri": "\(bobsLinks)", "name": "Links", "author": {"id": "did:plc:bob", "handle": "bob.test"}}
        ], "pagination": {"currentPage": 1, "hasMore": false}}
        """)

        let found = try await SharedCollectionsClient(http: http).search("l")

        XCTAssertEqual(found.map(\.name), ["Links"])
    }

    func testARefIsReadFromTheOwnersPDSWithoutAuth() async throws {
        let http = StubHTTPClient()
        http.stubSharedCollectionOwner()

        let ref = try await SharedCollectionsClient(http: http).ref(for: bobsLinks)

        XCTAssertEqual(ref, StrongRef(uri: bobsLinks, cid: "bafybob"))
        let read = try XCTUnwrap(http.requests(to: SharedFixtures.bobsPDS.absoluteString).first)
        XCTAssertNil(read.headers["Authorization"])
        XCTAssertNil(read.headers["DPoP"])
        XCTAssertEqual(URLComponents(url: read.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "rkey" }?.value, "links")
    }

    func testAMissingRecordIsUnavailable() async {
        let http = StubHTTPClient()
        http.stubSharedCollectionOwner()
        http.on(SharedFixtures.bobsPDS.absoluteString, status: 400, json: #"{"error": "RecordNotFound"}"#)

        do {
            _ = try await SharedCollectionsClient(http: http).ref(for: bobsLinks)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? SharedCollectionsError, .unavailable)
        }
    }
}

/// Canned responses for Semble's shared-collection endpoints and a
/// collection owner's PDS. Shared with `ShareSheetSharedCollectionsTests`.
enum SharedFixtures {
    static let bobsPDS = URL(string: "https://pds.bob.example")!

    static func page(_ items: [(uri: String, name: String, handle: String)]) -> String {
        let collections = items.map { item in
            let did = ATURI(item.uri)?.did ?? ""
            return """
            {"id": "\(UUID().uuidString)", "uri": "\(item.uri)", "name": "\(item.name)", "accessType": "OPEN", "cardCount": 1,
             "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z",
             "author": {"id": "\(did)", "name": "\(item.handle)", "handle": "\(item.handle)"}}
            """
        }
        return """
        {"collections": [\(collections.joined(separator: ","))],
         "pagination": {"currentPage": 1, "totalPages": 1, "totalCount": \(items.count), "hasMore": false, "limit": 100},
         "sorting": {"sortBy": "updatedAt", "sortOrder": "desc"}}
        """
    }
}

extension StubHTTPClient {
    /// did:plc:bob's DID document, and his PDS serving any collection record with cid `bafybob`.
    func stubSharedCollectionOwner() {
        on("https://plc.directory/did:plc:bob", json: Fixtures.didDocument(did: "did:plc:bob", handle: "bob.test", pds: SharedFixtures.bobsPDS))
        on(SharedFixtures.bobsPDS.absoluteString + "/xrpc/com.atproto.repo.getRecord") { request in
            let rkey = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "rkey" }?.value ?? ""
            let body = """
            {"uri": "at://did:plc:bob/network.cosmik.collection/\(rkey)", "cid": "bafybob", "value": {"name": "Links", "accessType": "OPEN"}}
            """
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        }
    }
}
