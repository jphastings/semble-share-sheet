import Foundation
import XCTest
@testable import SembleKit

final class SaveQueueTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SaveQueueTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func queue(abandonedClaimAge: TimeInterval = 5 * 60) -> SaveQueue {
        SaveQueue(directory: directory, abandonedClaimAge: abandonedClaimAge)
    }

    private func pending(did: String = "did:plc:alice") -> PendingSave {
        PendingSave(did: did, url: URL(string: "https://example.com/article")!)
    }

    private func queuedFileExists(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString).appendingPathExtension("json").path)
    }

    private func failedFileExists(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString).appendingPathExtension("failed").path)
    }

    private func anyFileExists(_ id: UUID) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .contains { $0.hasPrefix(id.uuidString) } ?? false
    }

    // MARK: - attempt (the share sheet's own save)

    func testAttemptSavesAndRemovesTheQueuedFile() async throws {
        let queue = queue()
        let library = FakeLibrary()
        let save = pending()
        try queue.enqueue(save)

        let outcome = await queue.attempt(save, using: library)

        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(library.savedRequests.map(\.id), [save.id])
        XCTAssertFalse(anyFileExists(save.id), "a saved item should leave nothing queued")
    }

    func testAttemptWithATransientFailureLeavesTheItemQueued() async throws {
        let queue = queue()
        let library = FakeLibrary()
        library.saveError = URLError(.notConnectedToInternet)
        let save = pending()
        try queue.enqueue(save)

        let outcome = await queue.attempt(save, using: library)

        XCTAssertEqual(outcome, .queued)
        XCTAssertTrue(queuedFileExists(save.id), "a transient failure should release the claim, not lose the item")
    }

    func testAttemptWithAPermanentFailureRemovesTheItemEntirely() async throws {
        let queue = queue()
        let library = FakeLibrary()
        library.saveError = SembleLibraryError.noteTooLong
        let save = pending()
        try queue.enqueue(save)

        let outcome = await queue.attempt(save, using: library)

        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
        XCTAssertFalse(anyFileExists(save.id), "the share sheet is showing the error live; nothing should be left to retry silently")
    }

    // MARK: - drain

    func testDrainWritesEveryQueuedItemForTheGivenDID() async throws {
        let queue = queue()
        let library = FakeLibrary()
        let first = pending()
        let second = pending()
        try queue.enqueue(first)
        try queue.enqueue(second)

        await queue.drain(for: "did:plc:alice", using: library)

        XCTAssertEqual(Set(library.savedRequests.map(\.id)), Set([first.id, second.id]))
        XCTAssertFalse(anyFileExists(first.id))
        XCTAssertFalse(anyFileExists(second.id))
    }

    func testDrainLeavesAnotherDIDsItemsCompletelyUntouched() async throws {
        let queue = queue()
        let library = FakeLibrary()
        let mine = pending(did: "did:plc:alice")
        let theirs = pending(did: "did:plc:bob")
        try queue.enqueue(mine)
        try queue.enqueue(theirs)

        await queue.drain(for: "did:plc:alice", using: library)

        XCTAssertEqual(library.savedRequests.map(\.id), [mine.id])
        XCTAssertTrue(queuedFileExists(theirs.id), "a foreign DID's item must still be queued, unclaimed")
    }

    func testDrainParksAPermanentFailureRatherThanRetryingItForever() async throws {
        let queue = queue()
        let library = FakeLibrary()
        library.saveError = SembleLibraryError.unsupportedURL(URL(string: "mailto:a@b.com")!)
        let save = pending()
        try queue.enqueue(save)

        await queue.drain(for: "did:plc:alice", using: library)

        XCTAssertTrue(failedFileExists(save.id))
        XCTAssertFalse(queuedFileExists(save.id))
    }

    func testDrainReleasesAnItemAfterATransientFailureSoALaterDrainCanRetryIt() async throws {
        let queue = queue()
        let library = FakeLibrary()
        library.saveError = URLError(.timedOut)
        let save = pending()
        try queue.enqueue(save)

        await queue.drain(for: "did:plc:alice", using: library)

        XCTAssertTrue(queuedFileExists(save.id))
        XCTAssertEqual(library.savedRequests.count, 1)

        library.saveError = nil
        await queue.drain(for: "did:plc:alice", using: library)

        XCTAssertEqual(library.savedRequests.count, 2, "the second drain should retry the still-queued item")
        XCTAssertFalse(anyFileExists(save.id))
    }

    func testTwoConcurrentDrainsWriteEachItemExactlyOnce() async throws {
        let library = FakeLibrary()
        let items = (0 ..< 10).map { _ in pending() }
        let queueA = queue()
        for item in items { try queueA.enqueue(item) }
        let queueB = SaveQueue(directory: directory, abandonedClaimAge: 5 * 60)

        async let drainA: Void = queueA.drain(for: "did:plc:alice", using: library)
        async let drainB: Void = queueB.drain(for: "did:plc:alice", using: library)
        _ = await (drainA, drainB)

        let counts = Dictionary(grouping: library.savedRequests, by: \.id).mapValues(\.count)
        XCTAssertEqual(counts.count, items.count, "every item should have been attempted")
        XCTAssertTrue(counts.values.allSatisfy { $0 == 1 }, "no item should have been written twice: \(counts)")
    }

    func testAnAbandonedClaimIsReclaimedByALaterDrain() async throws {
        let queue = queue(abandonedClaimAge: 0.05)
        let library = FakeLibrary()
        let save = pending()
        try queue.enqueue(save)
        // Simulate a process that claimed the item and died before resolving it.
        let json = directory.appendingPathComponent(save.id.uuidString).appendingPathExtension("json")
        let inflight = directory.appendingPathComponent(save.id.uuidString).appendingPathExtension("inflight")
        try FileManager.default.moveItem(at: json, to: inflight)
        try? await Task.sleep(nanoseconds: 100_000_000)

        await queue.drain(for: "did:plc:alice", using: library)

        XCTAssertEqual(library.savedRequests.map(\.id), [save.id], "the stale claim should have been reclaimed and retried")
        XCTAssertFalse(anyFileExists(save.id))
    }

    // MARK: - pendingCollections

    func testPendingCollectionsReturnsOnesFromQueuedItemsOfThatDID() async throws {
        let queue = queue()
        let recipes = PendingCollection(name: "Recipes", accessType: .closed)
        try queue.enqueue(PendingSave(did: "did:plc:alice", url: URL(string: "https://example.com/a")!, newCollections: [recipes]))
        try queue.enqueue(PendingSave(did: "did:plc:bob", url: URL(string: "https://example.com/b")!, newCollections: [PendingCollection(name: "Bob's", accessType: .closed)]))

        XCTAssertEqual(queue.pendingCollections(for: "did:plc:alice"), [recipes])
    }

    func testPendingCollectionsDedupesByRkeyAcrossSaves() async throws {
        let queue = queue()
        let recipes = PendingCollection(name: "Recipes", accessType: .closed)
        try queue.enqueue(PendingSave(did: "did:plc:alice", url: URL(string: "https://example.com/a")!, newCollections: [recipes]))
        try queue.enqueue(PendingSave(did: "did:plc:alice", url: URL(string: "https://example.com/b")!, newCollections: [recipes]))

        XCTAssertEqual(queue.pendingCollections(for: "did:plc:alice"), [recipes])
    }

    func testPendingCollectionsIncludesAClaimedInFlightItem() async throws {
        let queue = queue()
        let recipes = PendingCollection(name: "Recipes", accessType: .closed)
        let save = PendingSave(did: "did:plc:alice", url: URL(string: "https://example.com/a")!, newCollections: [recipes])
        try queue.enqueue(save)
        // Simulate a drain that has claimed the item but not yet resolved it.
        let json = directory.appendingPathComponent(save.id.uuidString).appendingPathExtension("json")
        let inflight = directory.appendingPathComponent(save.id.uuidString).appendingPathExtension("inflight")
        try FileManager.default.moveItem(at: json, to: inflight)

        XCTAssertEqual(queue.pendingCollections(for: "did:plc:alice"), [recipes])
    }

    func testPendingCollectionsExcludesAFailedItem() async throws {
        let queue = queue()
        let recipes = PendingCollection(name: "Recipes", accessType: .closed)
        let save = PendingSave(did: "did:plc:alice", url: URL(string: "https://example.com/a")!, newCollections: [recipes])
        try queue.enqueue(save)
        let library = FakeLibrary()
        library.saveError = SembleLibraryError.unsupportedURL(URL(string: "https://example.com/a")!)
        await queue.drain(for: "did:plc:alice", using: library) // permanent failure: parked as `.failed`

        XCTAssertEqual(queue.pendingCollections(for: "did:plc:alice"), [])
    }

    // MARK: - createdAt survives the round trip

    func testADrainedItemIsWrittenWithItsOriginalSavedAt() async throws {
        let queue = queue()
        let library = FakeLibrary()
        let tapTime = Date(timeIntervalSince1970: 1_700_000_000)
        let save = PendingSave(did: "did:plc:alice", url: URL(string: "https://example.com")!, savedAt: tapTime)
        try queue.enqueue(save)

        await queue.drain(for: "did:plc:alice", using: library)

        XCTAssertEqual(library.savedRequests.first?.savedAt, tapTime)
    }
}
