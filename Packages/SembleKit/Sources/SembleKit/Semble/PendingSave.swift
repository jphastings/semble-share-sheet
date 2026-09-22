import Foundation

/// A save the user has committed to, kept on disk until its records are
/// written. Unlike a finished `SaveResult`, a `PendingSave` can't hold strong
/// refs for records that don't exist yet — a strong ref's `cid` only the PDS
/// can give out — so it holds the *intent* plus the record keys chosen for
/// it, which is what lets `SembleLibrary.save(_:)` write it more than once
/// (from a retry, or from an unrelated drain) without duplicating anything.
public struct PendingSave: Codable, Equatable, Sendable {
    public let id: UUID
    /// The DID this save belongs to; a drain only ever touches its own DID's items.
    public let did: String
    public var url: URL
    public var preview: URLPreview?
    public var note: String?
    public var collections: [StrongRef]
    /// Collections this save is creating — offline collection creation is
    /// just another part of the save's intent, written before the card (see
    /// `SembleLibrary.save`) so the links below have somewhere to point.
    public var newCollections: [PendingCollection]
    /// The moment the user tapped Save. Written as every record's
    /// `createdAt`/`addedAt`, never the time it actually reaches the PDS.
    public let savedAt: Date

    public var cardRkey: String
    public var noteRkey: String
    /// Keyed by the linked collection's URI — of `collections` and
    /// `newCollections` alike — so a collection added after the save was
    /// first created gets its own fresh rkey while one already chosen (from
    /// an earlier attempt) is kept.
    public var linkRkeys: [String: String]

    public init(
        id: UUID = UUID(),
        did: String,
        url: URL,
        preview: URLPreview? = nil,
        note: String? = nil,
        collections: [StrongRef] = [],
        newCollections: [PendingCollection] = [],
        savedAt: Date = Date(),
        cardRkey: String? = nil,
        noteRkey: String? = nil,
        linkRkeys: [String: String] = [:]
    ) {
        self.id = id
        self.did = did
        self.url = url
        self.preview = preview
        self.note = note
        self.collections = collections
        self.newCollections = newCollections
        self.savedAt = savedAt
        self.cardRkey = cardRkey ?? TID.next()
        self.noteRkey = noteRkey ?? TID.next()
        self.linkRkeys = linkRkeys
        ensureLinkRkeys()
    }

    /// Mints an rkey for any selected collection — existing or newly
    /// created — that doesn't have one yet. Call this after changing
    /// `collections`/`newCollections` (the share sheet does, between a
    /// failed attempt and a retry); rkeys already chosen are left alone.
    public mutating func ensureLinkRkeys() {
        for collection in collections where linkRkeys[collection.uri] == nil {
            linkRkeys[collection.uri] = TID.next()
        }
        for newCollection in newCollections {
            let uri = newCollection.uri(did: did)
            if linkRkeys[uri] == nil {
                linkRkeys[uri] = TID.next()
            }
        }
    }
}
