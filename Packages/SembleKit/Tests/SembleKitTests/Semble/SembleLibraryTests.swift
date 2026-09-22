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

    private func pendingSave(
        did: String = "did:plc:alice",
        note: String? = nil,
        collections: [StrongRef] = []
    ) -> PendingSave {
        PendingSave(did: did, url: link, note: note, collections: collections, savedAt: fixedDate)
    }

    // MARK: - save

    func testSaveWritesTheCardBeforeAnyLink() async throws {
        let store = FakeRecordStore(did: "did:plc:alice")
        let library = makeLibrary(store: store)
        let reading = StrongRef(uri: "at://did:plc:alice/network.cosmik.collection/a", cid: "bafya")
        let later = StrongRef(uri: "at://did:plc:alice/network.cosmik.collection/b", cid: "bafyb")

        let result = try await library.save(pendingSave(collections: [reading, later]))

        XCTAssertEqual(store.writes.map(\.collection), [
            "network.cosmik.card",
            "network.cosmik.collectionLink",
            "network.cosmik.collectionLink",
        ])
        XCTAssertEqual(result.card.cid, "bafy1")
        XCTAssertNil(result.note)
        XCTAssertEqual(result.collectionLinks.count, 2)
    }

    func testLinksCarryTheCardRefAndTheUsersDID() async throws {
        let store = FakeRecordStore(did: "did:plc:alice")
        let library = makeLibrary(store: store)
        let reading = StrongRef(uri: "at://did:plc:alice/network.cosmik.collection/a", cid: "bafya")

        let result = try await library.save(pendingSave(collections: [reading]))

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

        let result = try await library.save(pendingSave())

        XCTAssertEqual(store.writes.map(\.collection), ["network.cosmik.card"])
        XCTAssertEqual(result.collectionLinks, [])
    }

    func testSaveWritesANoteCardBetweenTheCardAndTheLinks() async throws {
        let store = FakeRecordStore()
        let library = makeLibrary(store: store)
        let reading = StrongRef(uri: "at://did:plc:alice/network.cosmik.collection/a", cid: "bafya")

        let result = try await library.save(pendingSave(note: "  Worth a re-read  ", collections: [reading]))

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
        XCTAssertNotNil(result.note)
        // The link still points at the URL card, never at the note.
        let linkJSON = store.writes[2].json
        XCTAssertEqual((linkJSON["card"] as? [String: Any])?["uri"] as? String, result.card.uri)
    }

    func testSaveSkipsTheNoteWhenItIsBlank() async throws {
        let store = FakeRecordStore()
        let library = makeLibrary(store: store)

        let result = try await library.save(pendingSave(note: " \n\t "))

        XCTAssertEqual(store.writes.map(\.collection), ["network.cosmik.card"])
        XCTAssertNil(result.note)
    }

    func testSaveWritesThePreviewIntoTheCard() async throws {
        let store = FakeRecordStore()
        let library = makeLibrary(store: store)
        let preview = URLPreview(url: link, title: "Article", imageURL: URL(string: "https://example.com/i.png"))
        var pending = pendingSave()
        pending.preview = preview

        _ = try await library.save(pending)

        let card = store.writes[0].json
        let metadata = (card["content"] as? [String: Any])?["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["title"] as? String, "Article")
        XCTAssertEqual(metadata?["imageUrl"] as? String, "https://example.com/i.png")
    }

    func testSaveUsesTheOriginalTapTimeAsCreatedAt() async throws {
        let store = FakeRecordStore()
        // `now` would return a different time than `savedAt` if it were
        // consulted; it shouldn't be.
        let library = SembleLibrary(store: store, configuration: configuration, now: { Date(timeIntervalSince1970: 0) })
        let pending = PendingSave(did: "did:plc:alice", url: link, savedAt: fixedDate)

        _ = try await library.save(pending)

        XCTAssertEqual(store.writes[0].json["createdAt"] as? String, "2023-11-14T22:13:20.500Z")
    }

    func testSaveRejectsNonWebURLsBeforeWritingAnything() async {
        let store = FakeRecordStore()
        let library = makeLibrary(store: store)
        let mailto = URL(string: "mailto:someone@example.com")!
        let pending = PendingSave(did: "did:plc:alice", url: mailto, savedAt: fixedDate)

        do {
            _ = try await library.save(pending)
            XCTFail("expected an error")
        } catch let error as SembleLibraryError {
            XCTAssertEqual(error, .unsupportedURL(mailto))
            XCTAssertFalse(error.localizedDescription.isEmpty)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testSaveRejectsAnOverlongNoteBeforeWritingAnything() async {
        let store = FakeRecordStore()
        let library = makeLibrary(store: store)
        let tooLong = String(repeating: "a", count: 10_001)

        do {
            _ = try await library.save(pendingSave(note: tooLong))
            XCTFail("expected an error")
        } catch let error as SembleLibraryError {
            XCTAssertEqual(error, .noteTooLong)
            XCTAssertFalse(error.localizedDescription.isEmpty)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(store.writes.isEmpty)
    }

    // MARK: - idempotent retry

    func testRetryAfterALostResponseAdoptsTheExistingCardInsteadOfDuplicatingIt() async throws {
        let store = FakeRecordStore()
        let library = makeLibrary(store: store)
        let pending = pendingSave()

        let first = try await library.save(pending)
        // The client never saw the first response (dropped connection,
        // crash, whatever); it retries the very same `PendingSave`, rkeys
        // included.
        let second = try await library.save(pending)

        XCTAssertEqual(store.writtenRecords(in: "network.cosmik.card").count, 1, "no second card should reach the PDS")
        XCTAssertEqual(second.card, first.card)
    }

    func testRetryAdoptsTheOriginallyWrittenNoteRatherThanAnEditedOne() async throws {
        let store = FakeRecordStore()
        let library = makeLibrary(store: store)
        var pending = pendingSave(note: "original")

        let first = try await library.save(pending)
        pending.note = "edited after the fact"
        let second = try await library.save(pending)

        let notes = store.writtenRecords(in: "network.cosmik.card").filter { $0.rkey == pending.noteRkey }
        XCTAssertEqual(notes.count, 1, "the edit should not produce a second note record")
        XCTAssertEqual((notes.first?.json["content"] as? [String: Any])?["text"] as? String, "original")
        XCTAssertEqual(second.note, first.note)
    }

    func testRetryLinksEachCollectionAtMostOnce() async throws {
        let store = FakeRecordStore()
        let library = makeLibrary(store: store)
        let reading = StrongRef(uri: "at://did:plc:alice/network.cosmik.collection/a", cid: "bafya")
        let recipes = StrongRef(uri: "at://did:plc:alice/network.cosmik.collection/b", cid: "bafyb")
        let pending = pendingSave(collections: [reading, recipes])

        let first = try await library.save(pending)
        let second = try await library.save(pending)

        XCTAssertEqual(store.writtenRecords(in: "network.cosmik.collectionLink").count, 2)
        XCTAssertEqual(Set(second.collectionLinks), Set(first.collectionLinks))
    }

    func testConnectivityFailuresAreNotTreatedAsAlreadyWritten() async {
        let store = FakeRecordStore()
        store.createError = FakeRecordStore.Failure.injected
        let library = makeLibrary(store: store)

        do {
            _ = try await library.save(pendingSave())
            XCTFail("expected an error")
        } catch let error as FakeRecordStore.Failure {
            XCTAssertEqual(error, .injected, "a non-server error must be rethrown, not treated as a duplicate rkey")
        } catch {
            XCTFail("unexpected error \(error)")
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
