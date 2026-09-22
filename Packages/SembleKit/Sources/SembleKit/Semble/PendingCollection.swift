import Foundation

/// A collection created locally and not yet written to the PDS. Its rkey is
/// chosen up front (like `PendingSave`'s own rkeys), so its AT-URI is known
/// before it exists and it can be selected and linked from the picker right
/// away. `SembleLibrary.save` writes it, idempotently, the first time a save
/// that uses it actually reaches the PDS.
public struct PendingCollection: Codable, Equatable, Hashable, Sendable {
    public let rkey: String
    public var name: String
    public var accessType: CollectionAccessType
    /// The moment the user created it, not the time it's actually written.
    public let createdAt: Date

    public init(
        rkey: String = TID.next(),
        name: String,
        accessType: CollectionAccessType,
        createdAt: Date = Date()
    ) {
        self.rkey = rkey
        self.name = name
        self.accessType = accessType
        self.createdAt = createdAt
    }

    /// The AT-URI this collection will have once written — deterministic
    /// from the rkey chosen at creation time, so every save that selects it
    /// (and `SembleLibrary.save`, when it actually writes the record) agrees
    /// on the same URI without a round trip.
    public func uri(did: String, configuration: SembleConfiguration = .production) -> String {
        ATURI(did: did, collection: configuration.collectionCollection, rkey: rkey).description
    }
}
