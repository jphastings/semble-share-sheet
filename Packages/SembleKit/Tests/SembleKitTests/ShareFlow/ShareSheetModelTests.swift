import Combine
import Foundation
import XCTest
@testable import SembleKit

@MainActor
final class ShareSheetModelTests: XCTestCase {
    private let url = URL(string: "https://www.example.com/article")!

    // MARK: Loading

    func testLoadingWithNoURLLandsInNoURL() async {
        let library = FakeLibrary()
        let model = ShareSheetModel(library: library, metadata: Self.previewLoader(), url: nil)

        await model.load()

        XCTAssertEqual(model.phase, .noURL)
        XCTAssertFalse(model.canSave)
        XCTAssertEqual(library.collectionsRequests, 0, "nothing should be fetched without a URL")
    }

    func testLoadingWithoutALibraryLandsInNotSignedIn() async {
        let model = ShareSheetModel(library: nil, metadata: Self.previewLoader(), url: url)

        await model.load()

        XCTAssertEqual(model.phase, .notSignedIn)
        XCTAssertFalse(model.canSave)
    }

    func testMetadataFailureStillReachesReady() async {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        let model = ShareSheetModel(
            library: library,
            metadata: { _ in throw TestError("metadata down") },
            url: url
        )

        await model.load()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.preview)
        XCTAssertEqual(model.domain, "example.com")
        XCTAssertEqual(model.collections.map(\.name), ["Reading"])
        XCTAssertTrue(model.canSave)
    }

    func testSuccessfulLoadExposesPreviewAndCollections() async {
        let library = FakeLibrary(collections: [Self.collection("Reading"), Self.collection("Recipes")])
        let model = ShareSheetModel(library: library, metadata: Self.previewLoader(title: "An article"), url: url)

        await model.load()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.preview?.title, "An article")
        XCTAssertEqual(model.visibleCollections.map(\.name), ["Reading", "Recipes"])
    }

    func testCollectionsFailureIsReportedAndRetryable() async {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        library.collectionsError = TestError("Couldn't reach bsky.social")
        let model = ShareSheetModel(library: library, metadata: Self.previewLoader(), url: url)

        await model.load()
        XCTAssertEqual(model.phase, .failed("Couldn't reach bsky.social"))
        XCTAssertFalse(model.showsForm)
        XCTAssertFalse(model.canSave)

        library.collectionsError = nil
        await model.retry()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.collections.map(\.name), ["Reading"])
    }

    // MARK: Preview

    func testAPlainURLLoadsItsPreviewAutomatically() async {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        let loader = CountingLoader(title: "An article")
        let model = ShareSheetModel(library: library, metadata: loader.load, url: url)

        await model.load()
        let preview = await waitForPreview(model)

        XCTAssertEqual(loader.callCount, 1)
        XCTAssertEqual(preview?.title, "An article")
        XCTAssertFalse(model.previewAwaitingConfirmation)
    }

    func testAURLWithAQueryWaitsForConfirmationBeforeLoadingItsPreview() async {
        let sensitive = URL(string: "https://example.com/reset?token=secret")!
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        let loader = CountingLoader(title: "An article")
        let model = ShareSheetModel(library: library, metadata: loader.load, url: sensitive)

        await model.load()

        XCTAssertEqual(model.phase, .ready, "the URL is still ready to save without its preview")
        XCTAssertTrue(model.previewAwaitingConfirmation)
        XCTAssertEqual(loader.callCount, 0, "no request should be sent before the user asks")
        XCTAssertNil(model.preview)

        model.loadPreview()
        let preview = await waitForPreview(model)

        XCTAssertEqual(loader.callCount, 1)
        XCTAssertEqual(preview?.title, "An article")
        XCTAssertFalse(model.previewAwaitingConfirmation)
    }

    func testURLsWithAFragmentOrUserinfoAlsoWaitForConfirmation() async {
        let library = FakeLibrary(collections: [])
        let loader = CountingLoader()
        for unsafe in [
            URL(string: "https://example.com/article#section")!,
            URL(string: "https://user:pass@example.com/article")!,
        ] {
            let model = ShareSheetModel(library: library, metadata: loader.load, url: unsafe)
            await model.load()
            XCTAssertTrue(model.previewAwaitingConfirmation, unsafe.absoluteString)
        }
        XCTAssertEqual(loader.callCount, 0)
    }

    func testASlowOrNeverReturningPreviewDoesNotDelayReady() async {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        let model = ShareSheetModel(
            library: library,
            metadata: { url in
                try await Task.sleep(nanoseconds: 300_000_000)
                return URLPreview(url: url, title: "Late")
            },
            url: url
        )

        await model.load()

        XCTAssertEqual(model.phase, .ready, "ready shouldn't wait for the preview")
        XCTAssertNil(model.preview)

        let preview = await waitForPreview(model)
        XCTAssertEqual(preview?.title, "Late")
    }

    // MARK: Saving

    func testSaveSendsSelectedCollectionRefsAndTrimmedNote() async throws {
        let reading = Self.collection("Reading")
        let recipes = Self.collection("Recipes")
        let library = FakeLibrary(collections: [reading, recipes])
        let model = ShareSheetModel(library: library, metadata: Self.previewLoader(title: "An article"), url: url)
        await model.load()

        model.toggle(recipes)
        model.note = "  worth a second read \n"
        await model.save()

        XCTAssertEqual(model.phase, .saved)
        let request = try XCTUnwrap(library.savedRequests.first)
        XCTAssertEqual(library.savedRequests.count, 1)
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.preview?.title, "An article")
        XCTAssertEqual(request.note, "worth a second read")
        XCTAssertEqual(request.collections, [recipes.ref])
    }

    func testSaveOmitsBlankNoteAndUnselectedCollections() async throws {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        let model = ShareSheetModel(library: library, metadata: Self.previewLoader(), url: url)
        await model.load()

        model.note = "   \n"
        await model.save()

        let request = try XCTUnwrap(library.savedRequests.first)
        XCTAssertNil(request.note)
        XCTAssertTrue(request.collections.isEmpty)
    }

    func testToggleSelectsAndDeselects() async {
        let reading = Self.collection("Reading")
        let library = FakeLibrary(collections: [reading])
        let model = ShareSheetModel(library: library, metadata: Self.previewLoader(), url: url)
        await model.load()

        model.toggle(reading)
        XCTAssertEqual(model.selected, [reading.id])
        XCTAssertEqual(model.selectedCollections, [reading])

        model.toggle(reading)
        XCTAssertTrue(model.selected.isEmpty)
    }

    func testSaveFailureExposesMessageAndAllowsRetry() async {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        library.saveError = TestError("The PDS said no")
        let model = ShareSheetModel(library: library, metadata: Self.previewLoader(), url: url)
        await model.load()

        await model.save()

        XCTAssertEqual(model.phase, .failed("The PDS said no"))
        XCTAssertTrue(model.showsForm, "the form stays available so the user can retry")
        XCTAssertTrue(model.canSave)

        library.saveError = nil
        await model.retry()

        XCTAssertEqual(model.phase, .saved)
        XCTAssertEqual(library.savedRequests.count, 2)
    }

    func testSaveIsIgnoredBeforeLoading() async {
        let library = FakeLibrary()
        let model = ShareSheetModel(library: library, metadata: Self.previewLoader(), url: url)

        await model.save()

        XCTAssertEqual(model.phase, .loading)
        XCTAssertTrue(library.savedRequests.isEmpty)
    }

    // MARK: Collection picker

    func testCreateOptionAppearsOnlyForAnUnmatchedNonEmptyQuery() async {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        let model = ShareSheetModel(library: library, metadata: Self.previewLoader(), url: url)
        await model.load()

        model.query = ""
        XCTAssertFalse(model.canCreateCollection)

        model.query = "   "
        XCTAssertFalse(model.canCreateCollection)

        model.query = "reading"
        XCTAssertFalse(model.canCreateCollection, "an existing name (case-insensitive) is not offered for creation")
        XCTAssertEqual(model.visibleCollections.map(\.name), ["Reading"])

        model.query = " Read "
        XCTAssertTrue(model.canCreateCollection, "a partial match still allows creating the exact name")
        XCTAssertEqual(model.creationName, "Read")

        model.query = "Cooking"
        XCTAssertTrue(model.canCreateCollection)
        XCTAssertTrue(model.visibleCollections.isEmpty)
    }

    func testCreateCollectionSelectsTheNewCollectionAndClearsTheQuery() async {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        let model = ShareSheetModel(library: library, metadata: Self.previewLoader(), url: url)
        await model.load()

        model.query = "  Cooking "
        await model.createCollection()

        XCTAssertEqual(library.createdCollections.map(\.name), ["Cooking"])
        XCTAssertEqual(library.createdCollections.map(\.accessType), [.closed])
        XCTAssertEqual(model.collections.map(\.name), ["Cooking", "Reading"])
        XCTAssertEqual(model.query, "")
        XCTAssertFalse(model.canCreateCollection)
        XCTAssertNil(model.collectionError)

        let created = model.collections[0]
        XCTAssertTrue(model.selected.contains(created.id))
        XCTAssertEqual(model.phase, .ready)
    }

    func testCreateCollectionFailureIsReportedInline() async {
        let library = FakeLibrary(collections: [])
        library.createError = TestError("Couldn't create the collection")
        let model = ShareSheetModel(library: library, metadata: Self.previewLoader(), url: url)
        await model.load()

        model.query = "Cooking"
        await model.createCollection()

        XCTAssertEqual(model.collectionError, "Couldn't create the collection")
        XCTAssertEqual(model.query, "Cooking", "the query is kept so the user can try again")
        XCTAssertTrue(model.collections.isEmpty)
        XCTAssertEqual(model.phase, .ready, "a picker problem doesn't take the whole sheet down")
    }

    func testCreateCollectionIsIgnoredWhenNotOffered() async {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        let model = ShareSheetModel(library: library, metadata: Self.previewLoader(), url: url)
        await model.load()

        model.query = "reading"
        await model.createCollection()

        XCTAssertTrue(library.createdCollections.isEmpty)
    }

    // MARK: Fixtures

    private static func collection(_ name: String) -> CollectionSummary {
        let rkey = name.lowercased()
        return CollectionSummary(
            ref: StrongRef(uri: "at://did:plc:alice/network.cosmik.collection/\(rkey)", cid: "bafy\(rkey)"),
            name: name,
            accessType: .closed,
            description: nil
        )
    }

    private static func previewLoader(title: String? = nil) -> ShareSheetModel.MetadataLoader {
        return { url in
            URLPreview(url: url, title: title, description: nil, siteName: nil, type: nil, imageURL: nil)
        }
    }

    /// The preview is filled in by a detached `Task`, independently of
    /// `load()`/`loadPreview()` returning; this waits for that to land.
    @discardableResult
    private func waitForPreview(_ model: ShareSheetModel, timeout: TimeInterval = 2) async -> URLPreview? {
        if let preview = model.preview { return preview }
        let arrived = expectation(description: "preview arrives")
        let cancellable = model.$preview.dropFirst().sink { _ in arrived.fulfill() }
        await fulfillment(of: [arrived], timeout: timeout)
        cancellable.cancel()
        return model.preview
    }
}

// MARK: - Test doubles

/// A scripted `Library`: serves canned collections, records saves, and can be
/// told to fail any call.
private final class FakeLibrary: Library, @unchecked Sendable {
    var collections: [CollectionSummary]
    var collectionsError: Error?
    var createError: Error?
    var saveError: Error?

    private(set) var collectionsRequests = 0
    private(set) var createdCollections: [CollectionSummary] = []
    private(set) var savedRequests: [SaveRequest] = []

    init(collections: [CollectionSummary] = []) {
        self.collections = collections
    }

    func myCollections() async throws -> [CollectionSummary] {
        collectionsRequests += 1
        if let collectionsError { throw collectionsError }
        return collections
    }

    func createCollection(named name: String, accessType: CollectionAccessType) async throws -> CollectionSummary {
        if let createError { throw createError }
        let rkey = "new\(createdCollections.count + 1)"
        let created = CollectionSummary(
            ref: StrongRef(uri: "at://did:plc:alice/network.cosmik.collection/\(rkey)", cid: "bafy\(rkey)"),
            name: name,
            accessType: accessType,
            description: nil
        )
        createdCollections.append(created)
        collections.insert(created, at: 0)
        return created
    }

    func save(_ request: SaveRequest) async throws -> SaveResult {
        savedRequests.append(request)
        if let saveError { throw saveError }
        let card = StrongRef(uri: "at://did:plc:alice/network.cosmik.card/card1", cid: "bafycard1")
        let note = request.note.map { _ in StrongRef(uri: "at://did:plc:alice/network.cosmik.card/note1", cid: "bafynote1") }
        let links = request.collections.enumerated().map { index, _ in
            StrongRef(uri: "at://did:plc:alice/network.cosmik.collectionLink/link\(index)", cid: "bafylink\(index)")
        }
        return SaveResult(card: card, note: note, collectionLinks: links)
    }
}

private struct TestError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// A `MetadataLoader` that counts how many times it was asked for a preview.
private final class CountingLoader: @unchecked Sendable {
    private(set) var callCount = 0
    private let title: String?

    init(title: String? = nil) {
        self.title = title
    }

    func load(_ url: URL) async throws -> URLPreview {
        callCount += 1
        return URLPreview(url: url, title: title)
    }
}
