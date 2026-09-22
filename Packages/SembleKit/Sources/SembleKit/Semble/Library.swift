import Foundation

/// Who may add cards to a collection: anyone (`OPEN`) or only its owner and
/// collaborators (`CLOSED`).
public enum CollectionAccessType: String, Codable, CaseIterable, Sendable {
    case open = "OPEN"
    case closed = "CLOSED"
}

/// A collection as the picker needs it: enough to show it and to link a card
/// to it. `ref` is the strong ref a `CollectionLinkRecord` must carry.
public struct CollectionSummary: Identifiable, Hashable, Sendable, Codable {
    public var id: String { ref.uri }
    public let ref: StrongRef
    public let name: String
    public let accessType: CollectionAccessType
    public let description: String?

    public init(ref: StrongRef, name: String, accessType: CollectionAccessType, description: String? = nil) {
        self.ref = ref
        self.name = name
        self.accessType = accessType
        self.description = description
    }
}

/// The records a save produced, in the order they were written.
public struct SaveResult: Equatable, Sendable {
    public let card: StrongRef
    public let note: StrongRef?
    public let collectionLinks: [StrongRef]

    public init(card: StrongRef, note: StrongRef? = nil, collectionLinks: [StrongRef] = []) {
        self.card = card
        self.note = note
        self.collectionLinks = collectionLinks
    }
}

/// What the share sheet needs from Semble. A protocol so the UI can be
/// previewed and tested without a network.
public protocol Library: Sendable {
    func myCollections() async throws -> [CollectionSummary]
    func createCollection(named name: String, accessType: CollectionAccessType) async throws -> CollectionSummary
    /// Writes `pending`'s card, note and collection links. Safe to call more
    /// than once for the same `PendingSave` — its rkeys make every write
    /// idempotent — so a retry, or a drain racing a retry, never duplicates
    /// a record.
    func save(_ pending: PendingSave) async throws -> SaveResult
}

/// Validation failures raised before anything is written. Errors from the
/// PDS itself are passed through untouched.
public enum SembleLibraryError: LocalizedError, Equatable {
    /// Only `http` and `https` links can be saved; the share sheet is
    /// offered `mailto:`, `file:` and friends too.
    case unsupportedURL(URL)
    case emptyCollectionName
    /// The note exceeds `network.cosmik.card`'s `noteContent.text` limit.
    /// Checked before anything is written, so a save never strands a card.
    case noteTooLong

    public var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return "Semble can only save web links (http or https)."
        case .emptyCollectionName:
            return "Give the collection a name."
        case .noteTooLong:
            return "That note is too long to save — try trimming it."
        }
    }
}
