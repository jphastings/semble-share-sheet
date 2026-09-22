import Foundation
@testable import SembleKit

/// A scripted `Library`: serves canned collections, records saves, and can be
/// told to fail any call. Shared by `ShareSheetModelTests` and
/// `SaveQueueTests`.
final class FakeLibrary: Library, @unchecked Sendable {
    var collections: [CollectionSummary]
    var collectionsError: Error?
    /// Thrown by every `save(_:)` call until cleared.
    var saveError: Error?
    /// Overrides `saveError` for one rkey only, so a test can make a retry
    /// (same `PendingSave`, same rkeys) succeed where the first attempt failed.
    var saveErrorsByCardRkey: [String: Error] = [:]

    private let lock = NSLock()
    private var _collectionsRequests = 0
    private var _savedRequests: [PendingSave] = []

    var collectionsRequests: Int { lock.withLock { _collectionsRequests } }
    var savedRequests: [PendingSave] { lock.withLock { _savedRequests } }

    init(collections: [CollectionSummary] = []) {
        self.collections = collections
    }

    func myCollections() async throws -> [CollectionSummary] {
        lock.withLock { _collectionsRequests += 1 }
        if let collectionsError { throw collectionsError }
        return collections
    }

    func save(_ pending: PendingSave) async throws -> SaveResult {
        lock.withLock { _savedRequests.append(pending) }
        if let error = saveErrorsByCardRkey[pending.cardRkey] {
            throw error
        }
        if let saveError { throw saveError }
        let card = StrongRef(uri: "at://did:plc:alice/network.cosmik.card/\(pending.cardRkey)", cid: "bafycard")
        let note = pending.note.map { _ in StrongRef(uri: "at://did:plc:alice/network.cosmik.card/\(pending.noteRkey)", cid: "bafynote") }
        let links = pending.collections.map { collection in
            StrongRef(uri: "at://did:plc:alice/network.cosmik.collectionLink/\(pending.linkRkeys[collection.uri] ?? "?")", cid: "bafylink")
        }
        return SaveResult(card: card, note: note, collectionLinks: links)
    }
}
