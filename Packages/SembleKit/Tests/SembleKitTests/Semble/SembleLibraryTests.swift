import Foundation
import XCTest
@testable import SembleKit

final class SembleLibraryTests: XCTestCase {
    private let configuration = SembleConfiguration.production
    private let link = URL(string: "https://example.com/article")!
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000.5)

    private func makeLibrary(store: FakeRecordStore) -> SembleLibrary {
        let date = fixedDate
        return SembleLibrary(store: store, configuration: configuration, now: { date })
    }

    // MARK: - save

    func testSaveWritesTheCardBeforeAnyLink() async throws {
        let store = FakeRecordStore(did: "did:plc:alice")
        let library = makeLibrary(store: store)
        let reading = StrongRef(uri: "at://did:plc:alice/network.cosmik.collection/a", cid: "bafya")
        let later = StrongRef(uri: "at://did:plc:alice/network.cosmik.collection/b", cid: "bafyb")

        let result = try await library.save(SaveRequest(url: link, collections: [reading, later]))

        XCTAssertEqual(store.writes.map(\.collection), [
            "network.cosmik.card",
            "network.cosmik.collectionLink",
            "network.cosmik.collectionLink",
        ])
        XCTAssertEqual(result.card, StrongRef(uri: "at://did:plc:test/network.cosmik.card/1", cid: "bafy1"))
        XCTAssertNil(result.note)
        XCTAssertEqual(result.collectionLinks.count, 2)
    }

    func testLinksCarryTheCardRefAndTheUsersDID() async throws {
        let store = FakeRecordStore(did: "did:plc:alice")
        let library = makeLibrary(store: store)
        let reading = StrongRef(uri: "at://did:plc:alice/network.cosmik.collection/a", cid: "bafya")

        let result = try await library.save(SaveRequest(url: link, collections: [reading]))

        let links = store.writtenRecords(in: "network.cosmik.collectionLink")
        XCTAssertEqual(links.count, 1)
        let linkJSON = try XCTUnwrap(links.first?.json)
        XCTAssertEqual(linkJSON["$type"] as? String, "network.cosmik.collectionLink")
        XCTAssertEqual(linkJSON["addedBy"] as? String, "did:plc:alice")
        XCTAssertEqual((linkJSON["card"] as? [String: Any])?["uri"] as? String, result.card.uri)
        XCTAssertEqual((linkJSON["card"] as? [String: Any])?["cid"] as? String, result.card.cid)
        XCTAssertEqual((linkJSON["collection"] as? [String: Any])?["uri"] as? String, reading.uri)
        XCTAssertEqual((linkJSON["collection"] as? [String: Any])?["cid"] as? String, reading.cid)
        XCTAssertEqual(linkJSON["addedAt"] as? String, "2023-11-14T22:13:20.500Z")
        XCTAssertEqual(linkJSON["createdAt"] as? String, "2023-11-14T22:13:20.500Z")
    }

    func testSaveWithoutCollectionsWritesOnlyTheCard() async throws {
        let store = FakeRecordStore()
        let library = makeLibrary(store: store)

        let result = try await library.save(SaveRequest(url: link))

        XCTAssertEqual(store.writes.map(\.collection), ["network.cosmik.card"])
        XCTAssertEqual(result.collectionLinks, [])
    }

    func testSaveWritesANoteCardBetweenTheCardAndTheLinks() async throws {
        let store = FakeRecordStore()
        let library = makeLibrary(store: store)
        let reading = StrongRef(uri: "at://did:plc:alice/network.cosmik.collection/a", cid: "bafya")

        let result = try await library.save(SaveRequest(url: link, note: "  Worth a re-read  ", collections: [reading]))

        XCTAssertEqual(store.writes.map(\.collection), [
            "network.cosmik.card",
            "network.cosmik.card",
            "network.cosmik.collectionLink",
        ])
        let noteJSON = store.writes[1].json
        XCTAssertEqual(noteJSON["type"] as? String, "NOTE")
        XCTAssertEqual(noteJSON["url"] as? String, link.absoluteString)
        XCTAssertEqual((noteJSON["content"] as? [String: Any])?["text"] as? String, "Worth a re-read")
        XCTAssertEqual((noteJSON["parentCard"] as? [String: Any])?["uri"] as? String, result.card.uri)
        XCTAssertEqual(result.note?.uri, "at://did:plc:test/network.cosmik.card/2")
        // The link still points at the URL card, never at the note.
        let linkJSON = store.writes[2].json
        XCTAssertEqual((linkJSON["card"] as? [String: Any])?["uri"] as? String, result.card.uri)
    }

    func testSaveSkipsTheNoteWhenItIsBlank() async throws {
        let store = FakeRecordStore()
        let library = makeLibrary(store: store)

        let result = try await library.save(SaveRequest(url: link, note: " \n\t "))

        XCTAssertEqual(store.writes.map(\.collection), ["network.cosmik.card"])
        XCTAssertNil(result.note)
    }

    func testSaveWritesThePreviewIntoTheCard() async throws {
        let store = FakeRecordStore()
        let library = makeLibrary(store: store)
        let preview = URLPreview(url: link, title: "Article", imageURL: URL(string: "https://example.com/i.png"))

        _ = try await library.save(SaveRequest(url: link, preview: preview))

        let card = store.writes[0].json
        let metadata = (card["content"] as? [String: Any])?["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["title"] as? String, "Article")
        XCTAssertEqual(metadata?["imageUrl"] as? String, "https://example.com/i.png")
    }

    func testSaveRejectsNonWebURLsBeforeWritingAnything() async {
        let store = FakeRecordStore()
        let library = makeLibrary(store: store)
        let mailto = URL(string: "mailto:someone@example.com")!

        do {
            _ = try await library.save(SaveRequest(url: mailto))
            XCTFail("expected an error")
        } catch let error as SembleLibraryError {
            XCTAssertEqual(error, .unsupportedURL(mailto))
            XCTAssertFalse(error.localizedDescription.isEmpty)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testSavePropagatesStoreErrorsUnchanged() async {
        let store = FakeRecordStore()
        store.createError = FakeRecordStore.Failure.injected
        let library = makeLibrary(store: store)

        do {
            _ = try await library.save(SaveRequest(url: link))
            XCTFail("expected an error")
        } catch let error as FakeRecordStore.Failure {
            XCTAssertEqual(error, .injected)
        } catch {
            XCTFail("store error was wrapped: \(error)")
        }
    }

    // MARK: - myCollections

    func testMyCollectionsFollowsTheCursorAndSortsByName() async throws {
        let store = FakeRecordStore()
        store.servePage(FakeRecordStore.CannedPage(
            records: [
                FakeRecordStore.CannedRecord(uri: "at://did:plc:test/network.cosmik.collection/1", cid: "c1",
                      json: #"{"$type":"network.cosmik.collection","name":"zebra","accessType":"OPEN"}"#),
                FakeRecordStore.CannedRecord(uri: "at://did:plc:test/network.cosmik.collection/2", cid: "c2",
                      json: #"{"$type":"network.cosmik.collection","name":"Apples","accessType":"CLOSED","description":"Fruit"}"#),
            ],
            cursor: "page2"
        ))
        store.servePage(FakeRecordStore.CannedPage(
            records: [
                FakeRecordStore.CannedRecord(uri: "at://did:plc:test/network.cosmik.collection/3", cid: "c3",
                      json: #"{"$type":"network.cosmik.collection","name":"mangoes","accessType":"OPEN"}"#),
            ],
            cursor: nil
        ), forCursor: "page2")
        let library = makeLibrary(store: store)

        let collections = try await library.myCollections()

        XCTAssertEqual(store.listCalls, [
            FakeRecordStore.ListCall(collection: "network.cosmik.collection", limit: 100, cursor: nil),
            FakeRecordStore.ListCall(collection: "network.cosmik.collection", limit: 100, cursor: "page2"),
        ])
        XCTAssertEqual(collections.map(\.name), ["Apples", "mangoes", "zebra"])
        XCTAssertEqual(collections[0].ref, StrongRef(uri: "at://did:plc:test/network.cosmik.collection/2", cid: "c2"))
        XCTAssertEqual(collections[0].accessType, .closed)
        XCTAssertEqual(collections[0].description, "Fruit")
        XCTAssertEqual(collections[2].accessType, .open)
        XCTAssertEqual(collections[0].id, collections[0].ref.uri)
    }

    func testMyCollectionsDefaultsToClosedAndSkipsNamelessRecords() async throws {
        let store = FakeRecordStore()
        store.servePage(FakeRecordStore.CannedPage(
            records: [
                FakeRecordStore.CannedRecord(uri: "at://did:plc:test/network.cosmik.collection/1", cid: "c1",
                      json: #"{"$type":"network.cosmik.collection","name":"Odd","accessType":"SECRET"}"#),
                FakeRecordStore.CannedRecord(uri: "at://did:plc:test/network.cosmik.collection/2", cid: "c2",
                      json: #"{"$type":"network.cosmik.collection","name":"Missing type"}"#),
                FakeRecordStore.CannedRecord(uri: "at://did:plc:test/network.cosmik.collection/3", cid: "c3",
                      json: #"{"$type":"network.cosmik.collection","accessType":"OPEN"}"#),
            ],
            cursor: nil
        ))
        let library = makeLibrary(store: store)

        let collections = try await library.myCollections()

        XCTAssertEqual(collections.map(\.name), ["Missing type", "Odd"])
        XCTAssertEqual(collections.map(\.accessType), [.closed, .closed])
    }

    func testMyCollectionsIsEmptyWhenThereAreNoRecords() async throws {
        let store = FakeRecordStore()
        store.servePage(FakeRecordStore.CannedPage(records: [], cursor: nil))
        let library = makeLibrary(store: store)

        let collections = try await library.myCollections()

        XCTAssertEqual(collections, [])
        XCTAssertEqual(store.listCalls.count, 1)
    }

    // MARK: - createCollection

    func testCreateCollectionTrimsTheNameAndWritesAClosedRecord() async throws {
        let store = FakeRecordStore()
        let library = makeLibrary(store: store)

        let summary = try await library.createCollection(named: "  Reading list \n", accessType: .closed)

        XCTAssertEqual(summary.name, "Reading list")
        XCTAssertEqual(summary.accessType, .closed)
        XCTAssertEqual(summary.ref.uri, "at://did:plc:test/network.cosmik.collection/1")
        let json = try XCTUnwrap(store.writtenRecords(in: "network.cosmik.collection").first?.json)
        XCTAssertEqual(json["$type"] as? String, "network.cosmik.collection")
        XCTAssertEqual(json["name"] as? String, "Reading list")
        XCTAssertEqual(json["accessType"] as? String, "CLOSED")
        XCTAssertEqual(json["createdAt"] as? String, "2023-11-14T22:13:20.500Z")
        XCTAssertEqual(json["updatedAt"] as? String, "2023-11-14T22:13:20.500Z")
    }

    func testCreateCollectionRejectsBlankNames() async {
        let store = FakeRecordStore()
        let library = makeLibrary(store: store)

        do {
            _ = try await library.createCollection(named: "   ", accessType: .open)
            XCTFail("expected an error")
        } catch let error as SembleLibraryError {
            XCTAssertEqual(error, .emptyCollectionName)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(store.writes.isEmpty)
    }
}
