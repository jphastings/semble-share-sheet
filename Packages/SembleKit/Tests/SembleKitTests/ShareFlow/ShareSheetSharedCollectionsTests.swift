import Foundation
import XCTest
@testable import SembleKit

/// Other people's open collections in the share sheet: listed, searched,
/// selected and linked alongside the user's own, and never able to break
/// the sheet.
@MainActor
final class ShareSheetSharedCollectionsTests: XCTestCase {
    private let did = "did:plc:alice"
    private let contributedEndpoint = "https://api.semble.so/xrpc/network.cosmik.collection.listContributed"
    private let searchEndpoint = "https://api.semble.so/xrpc/network.cosmik.collection.search"
    private let bobsLinks = "at://did:plc:bob/network.cosmik.collection/links"
    private let bobsRecipes = "at://did:plc:bob/network.cosmik.collection/recipes"
    private let alicesOpen = "at://did:plc:alice/network.cosmik.collection/reading"

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ShareSheetSharedCollectionsTests-\(UUID().uuidString)")
    }

    private func makeModel(
        library: FakeLibrary? = nil,
        http: StubHTTPClient,
        cache: CollectionsCache? = nil
    ) -> ShareSheetModel {
        let model = ShareSheetModel(
            library: library ?? FakeLibrary(collections: [Self.ownReading]),
            metadata: { url in URLPreview(url: url) },
            url: URL(string: "https://example.com/article")!,
            did: did,
            queue: SaveQueue(directory: temporaryDirectory()),
            collectionsCache: cache,
            shared: SharedCollectionsClient(http: http)
        )
        model.searchDelay = 0
        return model
    }

    private func load(_ model: ShareSheetModel) async {
        await model.load()
        await model.contributedRefresh?.value
    }

    private func search(_ model: ShareSheetModel, for text: String) async {
        model.query = text
        await model.sharedSearch?.value
    }

    // MARK: Listing

    func testContributedCollectionsAreOfferedApartFromTheUsersOwn() async {
        let http = StubHTTPClient()
        http.on(contributedEndpoint, json: SharedFixtures.page([(uri: bobsLinks, name: "Links", handle: "bob.test")]))
        let model = makeModel(http: http)

        await load(model)

        XCTAssertEqual(model.visibleCollections.map(\.name), ["Reading"])
        XCTAssertEqual(model.visibleSharedCollections.map(\.name), ["Links"])
        XCTAssertEqual(model.visibleSharedCollections.first?.ownerHandle, "bob.test")
    }

    func testSearchingShowsMatchingOpenCollectionsButNotTheUsersOwnOrRepeats() async {
        let http = StubHTTPClient()
        http.on(contributedEndpoint, json: SharedFixtures.page([(uri: bobsLinks, name: "Links", handle: "bob.test")]))
        http.on(searchEndpoint, json: SharedFixtures.page([
            (uri: alicesOpen, name: "Reading", handle: "alice.test"),
            (uri: bobsRecipes, name: "Recipes", handle: "bob.test"),
            (uri: bobsRecipes, name: "Recipes", handle: "bob.test"),
        ]))
        let model = makeModel(http: http)
        await load(model)

        await search(model, for: "re")

        XCTAssertEqual(model.visibleCollections.map(\.name), ["Reading"])
        XCTAssertEqual(model.visibleSharedCollections.map(\.name), ["Recipes"])

        await search(model, for: "")
        XCTAssertEqual(model.visibleSharedCollections.map(\.name), ["Links"], "a cleared search goes back to the contributed list")
    }

    func testTypingQuicklySearchesOnlyForTheFinalText() async throws {
        let http = StubHTTPClient()
        http.on(contributedEndpoint, json: SharedFixtures.page([]))
        http.on(searchEndpoint, json: SharedFixtures.page([]))
        let model = makeModel(http: http)
        model.searchDelay = 50_000_000
        await load(model)

        model.query = "r"
        model.query = "re"
        await search(model, for: "rec")

        let searches = http.requests(to: searchEndpoint)
        XCTAssertEqual(searches.count, 1)
        let text = URLComponents(url: try XCTUnwrap(searches.first).url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "searchText" }?.value
        XCTAssertEqual(text, "rec")
    }

    // MARK: Saving

    func testASelectedSharedCollectionIsLinkedWithTheRefFromItsOwnersPDS() async throws {
        let http = StubHTTPClient()
        http.on(contributedEndpoint, json: SharedFixtures.page([(uri: bobsLinks, name: "Links", handle: "bob.test")]))
        http.stubSharedCollectionOwner()
        let library = FakeLibrary(collections: [Self.ownReading])
        let model = makeModel(library: library, http: http)
        await load(model)

        model.toggle(try XCTUnwrap(model.visibleSharedCollections.first))
        model.toggle(Self.ownReading)
        await model.save()

        XCTAssertEqual(model.phase, .saved)
        let saved = try XCTUnwrap(library.savedRequests.first)
        XCTAssertEqual(Set(saved.collections), [Self.ownReading.ref!, StrongRef(uri: bobsLinks, cid: "bafybob")])
    }

    func testASearchResultStaysSelectedAfterTheSearchIsCleared() async throws {
        let http = StubHTTPClient()
        http.on(contributedEndpoint, json: SharedFixtures.page([]))
        http.on(searchEndpoint, json: SharedFixtures.page([(uri: bobsRecipes, name: "Recipes", handle: "bob.test")]))
        http.stubSharedCollectionOwner()
        let library = FakeLibrary()
        let model = makeModel(library: library, http: http)
        await load(model)
        await search(model, for: "rec")
        model.toggle(try XCTUnwrap(model.visibleSharedCollections.first))

        await search(model, for: "")
        XCTAssertEqual(model.visibleSharedCollections.map(\.name), ["Recipes"], "still visible, so it can be unticked")
        await model.save()

        XCTAssertEqual(library.savedRequests.first?.collections, [StrongRef(uri: bobsRecipes, cid: "bafybob")])
    }

    func testASharedCollectionWhoseRecordCannotBeReadIsUntickedAndNotSilentlyDropped() async throws {
        let http = StubHTTPClient()
        http.on(contributedEndpoint, json: SharedFixtures.page([(uri: bobsLinks, name: "Links", handle: "bob.test")]))
        http.on("https://plc.directory/did:plc:bob") { _ in throw URLError(.notConnectedToInternet) }
        let library = FakeLibrary()
        let model = makeModel(library: library, http: http)
        await load(model)

        model.toggle(try XCTUnwrap(model.visibleSharedCollections.first))
        await model.save()

        XCTAssertEqual(model.phase, .failed("Couldn't reach “Links”, so it's been unticked."))
        XCTAssertTrue(library.savedRequests.isEmpty, "nothing is saved until the user has seen it go")
        XCTAssertFalse(model.selected.contains(bobsLinks))
        XCTAssertTrue(model.unavailableCollections.contains(bobsLinks))

        await model.retry()
        XCTAssertEqual(model.phase, .saved)
    }

    // MARK: Failure and offline

    func testSembleBeingDownLeavesTheUsersOwnCollectionsCreationAndSavingWorking() async {
        let http = StubHTTPClient()
        http.on("https://api.semble.so/") { _ in throw URLError(.cannotConnectToHost) }
        let library = FakeLibrary(collections: [Self.ownReading])
        let model = makeModel(library: library, http: http)

        await load(model)
        await search(model, for: "Cooking")

        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.visibleSharedCollections.isEmpty)
        XCTAssertTrue(model.canCreateCollection)
        model.createCollection()
        await model.save()
        XCTAssertEqual(model.phase, .saved)
        XCTAssertEqual(library.savedRequests.first?.newCollections.map(\.name), ["Cooking"])
    }

    func testOnlyTheUsersOwnCollectionsClashWithANewName() async {
        let http = StubHTTPClient()
        http.on(contributedEndpoint, json: SharedFixtures.page([(uri: bobsLinks, name: "Links", handle: "bob.test")]))
        let model = makeModel(http: http)
        await load(model)

        model.query = "links"

        XCTAssertTrue(model.canCreateCollection, "Bob's “Links” is his; the user can still make their own")
    }

    func testALookedUpSharedCollectionCanBeLinkedOfflineNextTime() async throws {
        let cache = CollectionsCache(directory: temporaryDirectory())
        let online = StubHTTPClient()
        online.on(contributedEndpoint, json: SharedFixtures.page([(uri: bobsLinks, name: "Links", handle: "bob.test")]))
        online.stubSharedCollectionOwner()
        let first = makeModel(http: online, cache: cache)
        await load(first)
        first.toggle(try XCTUnwrap(first.visibleSharedCollections.first))
        await first.save()

        let offline = StubHTTPClient()
        offline.on("https://") { _ in throw URLError(.notConnectedToInternet) }
        let library = FakeLibrary()
        library.collectionsError = URLError(.notConnectedToInternet)
        let second = makeModel(library: library, http: offline, cache: cache)
        await load(second)
        second.toggle(try XCTUnwrap(second.visibleSharedCollections.first))
        await second.save()

        XCTAssertEqual(library.savedRequests.first?.collections, [StrongRef(uri: bobsLinks, cid: "bafybob")])
    }

    // MARK: Fixtures

    private static let ownReading = CollectionSummary(
        ref: StrongRef(uri: "at://did:plc:alice/network.cosmik.collection/reading", cid: "bafyreading"),
        name: "Reading",
        accessType: .open
    )
}
