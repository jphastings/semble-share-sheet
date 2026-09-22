import Combine
import Foundation
import XCTest
@testable import SembleKit

@MainActor
final class ShareSheetModelTests: XCTestCase {
    private let url = URL(string: "https://www.example.com/article")!
    private let did = "did:plc:alice"

    // Each test gets its own uniquely-named directory under the system temp
    // directory; nothing here relies on cleaning them up afterwards.
    private func makeQueue() -> SaveQueue {
        SaveQueue(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ShareSheetModelTests-\(UUID().uuidString)"))
    }

    private func makeCache() -> CollectionsCache {
        CollectionsCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ShareSheetModelTests-cache-\(UUID().uuidString)"))
    }

    private func makeModel(
        library: (any Library)?,
        metadata: @escaping ShareSheetModel.MetadataLoader,
        url: URL?,
        did: String?,
        collectionsCache: CollectionsCache? = nil
    ) -> ShareSheetModel {
        ShareSheetModel(library: library, metadata: metadata, url: url, did: did, queue: makeQueue(), collectionsCache: collectionsCache)
    }

    // MARK: Loading

    func testLoadingWithNoURLLandsInNoURL() async {
        let library = FakeLibrary()
        let model = makeModel(library: library, metadata: Self.previewLoader(), url: nil, did: did)

        await model.load()

        XCTAssertEqual(model.phase, .noURL)
        XCTAssertFalse(model.canSave)
        XCTAssertEqual(library.collectionsRequests, 0, "nothing should be fetched without a URL")
    }

    func testLoadingWithoutALibraryLandsInNotSignedIn() async {
        let model = makeModel(library: nil, metadata: Self.previewLoader(), url: url, did: nil)

        await model.load()

        XCTAssertEqual(model.phase, .notSignedIn)
        XCTAssertFalse(model.canSave)
    }

    func testMetadataFailureStillReachesReady() async {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        let model = makeModel(
            library: library,
            metadata: { _ in throw TestError("metadata down") },
            url: url,
            did: did
        )

        await model.load()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.preview)
        XCTAssertEqual(model.domain, "example.com")
        XCTAssertEqual(model.collections.map(\.name), ["Reading"])
        XCTAssertTrue(model.canSave)
    }

    /// `load()` deliberately doesn't wait for the preview — it must never
    /// delay the form — so a test that asserts on the preview waits for the
    /// fetch to finish first.
    private func awaitPreviewFetch(on model: ShareSheetModel) async {
        var spins = 0
        while model.isLoadingPreview, spins < 1000 {
            spins += 1
            await Task.yield()
        }
    }

    func testSuccessfulLoadExposesPreviewAndCollections() async {
        let library = FakeLibrary(collections: [Self.collection("Reading"), Self.collection("Recipes")])
        let model = makeModel(library: library, metadata: Self.previewLoader(title: "An article"), url: url, did: did)

        await model.load()
        await awaitPreviewFetch(on: model)

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.preview?.title, "An article")
        XCTAssertEqual(model.visibleCollections.map(\.name), ["Reading", "Recipes"])
    }

    func testAPermanentCollectionsFailureWithNoCacheIsReportedAndRetryable() async {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        library.collectionsError = XRPCError.server(status: 403, error: nil, message: "Your account isn't allowed to do that.")
        let model = makeModel(library: library, metadata: Self.previewLoader(), url: url, did: did)

        await model.load()
        XCTAssertEqual(model.phase, .failed("Your account isn't allowed to do that."))
        XCTAssertFalse(model.showsForm)
        XCTAssertFalse(model.canSave)

        library.collectionsError = nil
        await model.retry()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.collections.map(\.name), ["Reading"])
    }

    func testATransientCollectionsFailureWithNoCacheStillReachesReadyWithAnEmptyList() async {
        let library = FakeLibrary()
        library.collectionsError = URLError(.notConnectedToInternet)
        let model = makeModel(library: library, metadata: Self.previewLoader(), url: url, did: did)

        await model.load()

        XCTAssertEqual(model.phase, .ready, "saving without collections must still work offline")
        XCTAssertEqual(model.collections, [])
        XCTAssertTrue(model.canSave)
    }

    func testOfflineLoadShowsCachedCollectionsInsteadOfFailing() async {
        let cache = makeCache()
        cache.save([Self.collection("Cached")], for: did)
        let library = FakeLibrary()
        library.collectionsError = URLError(.notConnectedToInternet)
        let model = makeModel(library: library, metadata: Self.previewLoader(), url: url, did: did, collectionsCache: cache)

        await model.load()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.collections.map(\.name), ["Cached"])

        model.query = "Recipes"
        XCTAssertTrue(model.canCreateCollection, "creating a collection is local and works offline")
    }

    func testASuccessfulLoadReplacesTheCache() async {
        let cache = makeCache()
        cache.save([Self.collection("Stale")], for: did)
        let library = FakeLibrary(collections: [Self.collection("Fresh")])
        let model = makeModel(library: library, metadata: Self.previewLoader(), url: url, did: did, collectionsCache: cache)

        await model.load()

        XCTAssertEqual(model.collections.map(\.name), ["Fresh"])
        XCTAssertEqual(cache.load(for: did)?.map(\.name), ["Fresh"])
    }

    // MARK: Preview

    func testAPlainURLLoadsItsPreviewAutomatically() async {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        let loader = CountingLoader(title: "An article")
        let model = makeModel(library: library, metadata: loader.load, url: url, did: did)

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
        let model = makeModel(library: library, metadata: loader.load, url: sensitive, did: did)

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
            let model = makeModel(library: library, metadata: loader.load, url: unsafe, did: did)
            await model.load()
            XCTAssertTrue(model.previewAwaitingConfirmation, unsafe.absoluteString)
        }
        XCTAssertEqual(loader.callCount, 0)
    }

    func testASlowOrNeverReturningPreviewDoesNotDelayReady() async {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        let model = makeModel(
            library: library,
            metadata: { url in
                try await Task.sleep(nanoseconds: 300_000_000)
                return URLPreview(url: url, title: "Late")
            },
            url: url,
            did: did
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
        let model = makeModel(library: library, metadata: Self.previewLoader(title: "An article"), url: url, did: did)
        await model.load()
        await awaitPreviewFetch(on: model)

        model.toggle(recipes)
        model.note = "  worth a second read \n"
        await model.save()

        XCTAssertEqual(model.phase, .saved)
        let saved = try XCTUnwrap(library.savedRequests.first)
        XCTAssertEqual(library.savedRequests.count, 1)
        XCTAssertEqual(saved.url, url)
        XCTAssertEqual(saved.preview?.title, "An article")
        XCTAssertEqual(saved.note, "worth a second read")
        XCTAssertEqual(saved.collections, [recipes.ref!])
        XCTAssertEqual(saved.did, did)
    }

    func testSaveOmitsBlankNoteAndUnselectedCollections() async throws {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        let model = makeModel(library: library, metadata: Self.previewLoader(), url: url, did: did)
        await model.load()

        model.note = "   \n"
        await model.save()

        let saved = try XCTUnwrap(library.savedRequests.first)
        XCTAssertNil(saved.note)
        XCTAssertTrue(saved.collections.isEmpty)
    }

    func testToggleSelectsAndDeselects() async {
        let reading = Self.collection("Reading")
        let library = FakeLibrary(collections: [reading])
        let model = makeModel(library: library, metadata: Self.previewLoader(), url: url, did: did)
        await model.load()

        model.toggle(reading)
        XCTAssertEqual(model.selected, [reading.id])
        XCTAssertEqual(model.selectedCollections, [reading])

        model.toggle(reading)
        XCTAssertTrue(model.selected.isEmpty)
    }

    func testAPermanentSaveFailureExposesMessageAndRetryReusesTheSamePendingSave() async throws {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        library.saveError = SembleLibraryError.noteTooLong
        let model = makeModel(library: library, metadata: Self.previewLoader(), url: url, did: did)
        await model.load()

        await model.save()

        XCTAssertEqual(model.phase, .failed("That note is too long to save — try trimming it."))
        XCTAssertTrue(model.showsForm, "the form stays available so the user can retry")
        XCTAssertTrue(model.canSave)
        let firstAttempt = try XCTUnwrap(library.savedRequests.first)

        library.saveError = nil
        await model.retry()

        XCTAssertEqual(model.phase, .saved)
        XCTAssertEqual(library.savedRequests.count, 2)
        XCTAssertEqual(library.savedRequests.last?.id, firstAttempt.id, "a retry reuses the same pending save rather than starting a fresh one")
        XCTAssertEqual(library.savedRequests.last?.cardRkey, firstAttempt.cardRkey, "reusing the rkey is what makes the retry idempotent")
    }

    func testATransientSaveFailureEndsQueuedAndALaterDrainWritesItWithTheOriginalTapTime() async throws {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        library.saveError = URLError(.notConnectedToInternet)
        let queue = makeQueue()
        let model = ShareSheetModel(library: library, metadata: Self.previewLoader(), url: url, did: did, queue: queue)
        await model.load()
        let beforeTap = Date()

        await model.save()

        XCTAssertEqual(model.phase, .queued)
        let queuedAttempt = try XCTUnwrap(library.savedRequests.first)
        XCTAssertGreaterThanOrEqual(queuedAttempt.savedAt, beforeTap)
        XCTAssertLessThanOrEqual(queuedAttempt.savedAt, Date())

        library.saveError = nil
        await queue.drain(for: did, using: library)

        XCTAssertEqual(library.savedRequests.count, 2)
        XCTAssertEqual(library.savedRequests.last?.savedAt, queuedAttempt.savedAt, "the drain must write the original tap time, not the sync time")
    }

    func testSaveIsIgnoredBeforeLoading() async {
        let library = FakeLibrary()
        let model = makeModel(library: library, metadata: Self.previewLoader(), url: url, did: did)

        await model.save()

        XCTAssertEqual(model.phase, .loading)
        XCTAssertTrue(library.savedRequests.isEmpty)
    }

    // MARK: Collection picker

    func testCreateOptionAppearsOnlyForAnUnmatchedNonEmptyQuery() async {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        let model = makeModel(library: library, metadata: Self.previewLoader(), url: url, did: did)
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

    func testCreateCollectionIsLocalAndSelectsTheNewCollectionAndClearsTheQuery() async {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        let model = makeModel(library: library, metadata: Self.previewLoader(), url: url, did: did)
        await model.load()
        let requestsBeforeCreating = library.collectionsRequests

        model.query = "  Cooking "
        model.createCollection()

        XCTAssertEqual(library.collectionsRequests, requestsBeforeCreating, "creating a collection must not touch the network")
        XCTAssertEqual(model.collections.map(\.name), ["Cooking", "Reading"])
        XCTAssertEqual(model.query, "")
        XCTAssertFalse(model.canCreateCollection)

        let created = model.collections[0]
        XCTAssertNotNil(created.pending, "nothing was written, so it has no PDS record yet")
        XCTAssertNil(created.ref)
        XCTAssertTrue(model.selected.contains(created.id))
        XCTAssertEqual(model.phase, .ready)
    }

    func testCreateCollectionIsIgnoredWhenNotOffered() async {
        let library = FakeLibrary(collections: [Self.collection("Reading")])
        let model = makeModel(library: library, metadata: Self.previewLoader(), url: url, did: did)
        await model.load()

        model.query = "reading"
        model.createCollection()

        XCTAssertEqual(model.collections.map(\.name), ["Reading"], "no collection should have been created")
    }

    // MARK: Pending collections (created offline, not yet synced)

    func testAPendingCollectionFromAQueuedSaveAppearsInAFreshModelsPicker() async throws {
        let queue = makeQueue()
        let recipes = PendingCollection(name: "Recipes", accessType: .closed)
        try queue.enqueue(PendingSave(did: did, url: URL(string: "https://example.com/other")!, newCollections: [recipes]))

        let library = FakeLibrary(collections: [Self.collection("Reading")])
        let model = ShareSheetModel(library: library, metadata: Self.previewLoader(), url: url, did: did, queue: queue)

        await model.load()

        let found = try XCTUnwrap(model.collections.first { $0.name == "Recipes" })
        XCTAssertEqual(found.pending, recipes)
        XCTAssertEqual(found.id, recipes.uri(did: did))
    }

    func testAPendingCollectionIsNotDuplicatedOnceTheNetworkListContainsItsURI() async throws {
        let queue = makeQueue()
        let recipes = PendingCollection(name: "Recipes", accessType: .closed)
        try queue.enqueue(PendingSave(did: did, url: URL(string: "https://example.com/other")!, newCollections: [recipes]))
        // Another save's copy already synced: the network now knows this collection by its real (chosen) rkey's URI.
        let synced = CollectionSummary(ref: StrongRef(uri: recipes.uri(did: did), cid: "bafyrecipes"), name: "Recipes", accessType: .closed)
        let library = FakeLibrary(collections: [synced])
        let model = ShareSheetModel(library: library, metadata: Self.previewLoader(), url: url, did: did, queue: queue)

        await model.load()

        XCTAssertEqual(model.collections.filter { $0.name == "Recipes" }.count, 1, "the synced copy must win, not sit alongside a pending duplicate")
        XCTAssertNil(model.collections.first { $0.name == "Recipes" }?.pending)
    }

    func testSelectingAPendingCollectionInASecondSaveCarriesTheSameRkey() async throws {
        let queue = makeQueue()
        let recipes = PendingCollection(name: "Recipes", accessType: .closed)
        try queue.enqueue(PendingSave(did: did, url: URL(string: "https://example.com/other")!, newCollections: [recipes]))

        let library = FakeLibrary(collections: [Self.collection("Reading")])
        let model = ShareSheetModel(library: library, metadata: Self.previewLoader(), url: url, did: did, queue: queue)
        await model.load()
        let offered = try XCTUnwrap(model.collections.first { $0.name == "Recipes" })

        model.toggle(offered)
        await model.save()

        let saved = try XCTUnwrap(library.savedRequests.first)
        XCTAssertEqual(saved.newCollections, [recipes], "the second save must reuse the same rkey rather than minting a new one")
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
