import XCTest
@testable import SembleKit

final class IdentityResolverTests: XCTestCase {
    private var stub: StubHTTPClient!
    private var resolver: IdentityResolver!

    override func setUp() {
        super.setUp()
        stub = StubHTTPClient()
        resolver = IdentityResolver(http: stub)
    }

    func test_resolvesHandleViaPublicAPIAndVerifiesTheDIDDocumentPointsBack() async throws {
        stub.stubIdentity()

        // Whitespace, a leading @ and capitals are all things people type.
        let identity = try await resolver.resolve("  @Alice.Example.com ")

        XCTAssertEqual(identity.did, Fixtures.did)
        XCTAssertEqual(identity.handle, Fixtures.handle)
        XCTAssertEqual(identity.pdsURL, Fixtures.pdsURL)

        let lookup = try XCTUnwrap(stub.requests(to: "https://public.api.bsky.app").first)
        XCTAssertEqual(queryParameters(of: lookup.url)["handle"], "alice.example.com")
    }

    func test_rejectsAHandleTheDIDDocumentDoesNotClaim() async {
        stub.stubIdentity(handle: "someone-else.example.com")

        let error = await errorThrown { try await resolver.resolve(Fixtures.handle) }

        XCTAssertEqual(error as? IdentityError, .handleMismatch(handle: Fixtures.handle, did: Fixtures.did))
    }

    func test_fallsBackToTheHandlesWellKnownWhenThePublicAPIFails() async throws {
        stub.on("https://public.api.bsky.app", status: 502, json: #"{"error": "Bad Gateway"}"#)
        stub.on("https://alice.example.com/.well-known/atproto-did") { _ in
            HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/plain"], body: Data("\(Fixtures.did)\n".utf8))
        }
        stub.on("https://plc.directory/\(Fixtures.did)", json: Fixtures.didDocument())

        let identity = try await resolver.resolve(Fixtures.handle)

        XCTAssertEqual(identity.did, Fixtures.did)
        XCTAssertEqual(stub.requests(to: "https://alice.example.com/.well-known/atproto-did").count, 1)
    }

    func test_resolvesDIDWebFromTheHostsWellKnown() async throws {
        let did = "did:web:pds.example"
        stub.on("https://pds.example/.well-known/did.json", json: Fixtures.didDocument(did: did, handle: "bob.pds.example"))

        let identity = try await resolver.resolve(did)

        XCTAssertEqual(identity.did, did)
        XCTAssertEqual(identity.handle, "bob.pds.example")
        XCTAssertEqual(identity.pdsURL, Fixtures.pdsURL)
        XCTAssertTrue(stub.requests(to: "https://public.api.bsky.app").isEmpty, "a DID needs no handle lookup")
    }

    func test_resolvesDIDPLCFromTheDirectory() async throws {
        stub.on("https://plc.directory/\(Fixtures.did)", json: Fixtures.didDocument())

        let identity = try await resolver.resolve(Fixtures.did)

        XCTAssertEqual(identity.handle, Fixtures.handle)
        XCTAssertEqual(identity.pdsURL, Fixtures.pdsURL)
    }

    func test_rejectsInputThatIsNotAHandleOrDID() async {
        let empty = await errorThrown { try await resolver.resolve("   ") }
        XCTAssertEqual(empty as? IdentityError, .emptyAccount)

        let bare = await errorThrown { try await resolver.resolve("alice") }
        XCTAssertEqual(bare as? IdentityError, .invalidHandle("alice"))

        let unknownMethod = await errorThrown { try await resolver.resolve("did:key:zQ3sh") }
        XCTAssertEqual(unknownMethod as? IdentityError, .unsupportedDID("did:key:zQ3sh"))

        XCTAssertTrue(stub.requests.isEmpty, "nothing should hit the network")
    }

    func test_rejectsAnUnknownHandle() async {
        stub.on("https://public.api.bsky.app", status: 400, json: #"{"error": "InvalidRequest", "message": "Unable to resolve handle"}"#)
        stub.on("https://alice.example.com/.well-known/atproto-did", status: 404, json: "{}")

        let error = await errorThrown { try await resolver.resolve(Fixtures.handle) }

        XCTAssertEqual(error as? IdentityError, .handleNotFound(Fixtures.handle))
    }

    func test_rejectsADocumentWithoutAPDS() async {
        stub.stubIdentity()
        stub.on("https://plc.directory/\(Fixtures.did)", json: Fixtures.didDocument(pds: nil))

        let error = await errorThrown { try await resolver.resolve(Fixtures.handle) }

        XCTAssertEqual(error as? IdentityError, .noPDS(Fixtures.did))
    }

    func test_rejectsADocumentAboutADifferentDID() async {
        stub.stubIdentity()
        stub.on("https://plc.directory/\(Fixtures.did)", json: Fixtures.didDocument(did: "did:plc:other"))

        let error = await errorThrown { try await resolver.resolve(Fixtures.did) }

        XCTAssertEqual(error as? IdentityError, .invalidDIDDocument(Fixtures.did, reason: "it describes did:plc:other"))
    }

    func test_errorsReadLikeSentences() {
        XCTAssertEqual(
            IdentityError.handleNotFound("alice.example.com").localizedDescription,
            "Couldn't find an account for alice.example.com. Check the spelling and try again."
        )
    }
}
