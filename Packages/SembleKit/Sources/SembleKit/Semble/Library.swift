import Foundation

/// Who may add cards to a collection: anyone (`OPEN`) or only its owner and
/// collaborators (`CLOSED`).
public enum CollectionAccessType: String, Codable, CaseIterable, Sendable {
    case open = "OPEN"
    case closed = "CLOSED"
}

/// A collection as the picker needs it: enough to show it and to link a card
/// to it. `ref` is the strong ref a `CollectionLinkRecord` must carry.
public struct CollectionSummary: Identifiable, Hashable, Sendable {
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

/// Everything the share sheet has gathered by the time the user taps Add.
public struct SaveRequest: Equatable, Sendable {
    public var url: URL
    /// Metadata from `URLMetadataClient`, if the lookup succeeded. It is
    /// written into the card so Semble can render it immediately.
    public var preview: URLPreview?
    /// An optional note; blank notes are ignored.
    public var note: String?
    /// Collections to add the card to (strong refs from `CollectionSummary.ref`).
    public var collections: [StrongRef]

    public init(url: URL, preview: URLPreview? = nil, note: String? = nil, collections: [StrongRef] = []) {
        self.url = url
        self.preview = preview
        self.note = note
        self.collections = collections
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
    func save(_ request: SaveRequest) async throws -> SaveResult
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
