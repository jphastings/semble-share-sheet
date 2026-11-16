import Foundation
import XCTest
@testable import SembleKit

final class CollectionsCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CollectionsCacheTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func collection(_ name: String) -> CollectionSummary {
        CollectionSummary(ref: StrongRef(uri: "at://did:plc:alice/network.cosmik.collection/\(name)", cid: "bafy\(name)"), name: name, accessType: .closed)
    }

    func testANeverSavedDIDHasNoCache() {
        let cache = CollectionsCache(directory: directory)
        XCTAssertNil(cache.load(for: "did:plc:alice"))
    }

    func testSavedCollectionsLoadBackEqualForTheSameDID() {
        let cache = CollectionsCache(directory: directory)
        let collections = [collection("Reading"), collection("Recipes")]

        cache.save(collections, for: "did:plc:alice")

        XCTAssertEqual(cache.load(for: "did:plc:alice"), collections)
    }

    func testEachDIDHasItsOwnCache() {
        let cache = CollectionsCache(directory: directory)
        cache.save([collection("Alice's")], for: "did:plc:alice")
        cache.save([collection("Bob's")], for: "did:plc:bob")

        XCTAssertEqual(cache.load(for: "did:plc:alice")?.map(\.name), ["Alice's"])
        XCTAssertEqual(cache.load(for: "did:plc:bob")?.map(\.name), ["Bob's"])
    }

    func testSavingAgainReplacesTheEarlierList() {
        let cache = CollectionsCache(directory: directory)
        cache.save([collection("Old")], for: "did:plc:alice")

        cache.save([collection("New")], for: "did:plc:alice")

        XCTAssertEqual(cache.load(for: "did:plc:alice")?.map(\.name), ["New"])
    }

    func testSharedCollectionsAreCachedApartFromTheUsersOwn() {
        let cache = CollectionsCache(directory: directory)
        let bobs = CollectionSummary(
            ref: StrongRef(uri: "at://did:plc:bob/network.cosmik.collection/links", cid: "bafybob"),
            name: "Links", accessType: .open, ownerHandle: "bob.test"
        )
        cache.save([collection("Reading")], for: "did:plc:alice")

        cache.save([bobs], for: "did:plc:alice", shared: true)

        XCTAssertEqual(cache.load(for: "did:plc:alice")?.map(\.name), ["Reading"])
        XCTAssertEqual(cache.load(for: "did:plc:alice", shared: true), [bobs])
    }

    func testAFileWrittenBeforeSharedCollectionsExistedStillLoads() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldFormat = """
        [{"id": "at://did:plc:alice/network.cosmik.collection/reading",
          "ref": {"uri": "at://did:plc:alice/network.cosmik.collection/reading", "cid": "bafyreading"},
          "name": "Reading", "accessType": "CLOSED"}]
        """
        try Data(oldFormat.utf8).write(to: directory.appendingPathComponent("did%3Aplc%3Aalice.json"))

        let loaded = CollectionsCache(directory: directory).load(for: "did:plc:alice")

        XCTAssertEqual(loaded, [CollectionSummary(
            ref: StrongRef(uri: "at://did:plc:alice/network.cosmik.collection/reading", cid: "bafyreading"),
            name: "Reading", accessType: .closed
        )])
    }

    func testACacheSurvivesBeingReopenedFromTheSameDirectory() {
        let collections = [collection("Reading")]
        CollectionsCache(directory: directory).save(collections, for: "did:plc:alice")

        let reopened = CollectionsCache(directory: directory)

        XCTAssertEqual(reopened.load(for: "did:plc:alice"), collections)
    }
}
