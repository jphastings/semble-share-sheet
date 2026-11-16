import Foundation

/// Who may add cards to a collection: anyone (`OPEN`) or only its owner and
/// collaborators (`CLOSED`).
public enum CollectionAccessType: String, Codable, CaseIterable, Sendable {
    case open = "OPEN"
    case closed = "CLOSED"
}

/// A collection as the picker needs it: enough to show it and to link a card
/// to it. `ref` is the strong ref a `CollectionLinkRecord` must carry, and
/// is set for a collection whose record (and so cid) is known. `pending` is
/// set instead for one of the user's own created locally and not yet
/// written — it has no cid, so there is deliberately no way to build a
/// `StrongRef` for it (which could otherwise reach a link record empty). A
/// shared collection (someone else's, `ownerHandle` set) has neither until
/// its cid is looked up; see `SharedCollectionsClient.ref(for:)`.
public struct CollectionSummary: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let ref: StrongRef?
    public let pending: PendingCollection?
    public let name: String
    public let accessType: CollectionAccessType
    public let description: String?
    /// The owner's handle, for a collection that isn't the user's own.
    public let ownerHandle: String?

    /// A collection that already has a record on a PDS.
    public init(ref: StrongRef, name: String, accessType: CollectionAccessType, description: String? = nil, ownerHandle: String? = nil) {
        self.id = ref.uri
        self.ref = ref
        self.pending = nil
        self.name = name
        self.accessType = accessType
        self.description = description
        self.ownerHandle = ownerHandle
    }

    /// Someone else's collection whose cid isn't known yet.
    public init(sharedURI uri: String, name: String, accessType: CollectionAccessType, description: String? = nil, ownerHandle: String?) {
        self.id = uri
        self.ref = nil
        self.pending = nil
        self.name = name
        self.accessType = accessType
        self.description = description
        self.ownerHandle = ownerHandle
    }

    /// A collection created locally and not yet written to the PDS.
    public init(pending: PendingCollection, did: String, configuration: SembleConfiguration = .production) {
        self.id = pending.uri(did: did, configuration: configuration)
        self.ref = nil
        self.pending = pending
        self.name = pending.name
        self.accessType = pending.accessType
        self.description = nil
        self.ownerHandle = nil
    }

    /// This collection with its cid looked up.
    func with(ref: StrongRef) -> CollectionSummary {
        CollectionSummary(ref: ref, name: name, accessType: accessType, description: description, ownerHandle: ownerHandle)
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
    /// Writes `pending`'s new collections, card, note and collection links,
    /// in that order. Safe to call more than once for the same `PendingSave`
    /// — its rkeys make every write idempotent — so a retry, or a drain
    /// racing a retry, never duplicates a record.
    func save(_ pending: PendingSave) async throws -> SaveResult
}

/// Validation failures raised before anything is written. Errors from the
/// PDS itself are passed through untouched.
public enum SembleLibraryError: LocalizedError, Equatable {
    /// Only `http` and `https` links can be saved; the share sheet is
    /// offered `mailto:`, `file:` and friends too.
    case unsupportedURL(URL)
    /// The note exceeds `network.cosmik.card`'s `noteContent.text` limit.
    /// Checked before anything is written, so a save never strands a card.
    case noteTooLong
    /// The save was made by a different account than the one signed in.
    /// Nothing is written; it stays queued for its own account.
    case differentAccount

    public var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return "Semble can only save web links (http or https)."
        case .noteTooLong:
            return "That note is too long to save — try trimming it."
        case .differentAccount:
            return "This save belongs to a different Semble account."
        }
    }
}
