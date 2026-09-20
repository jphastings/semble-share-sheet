import Foundation

/// A `network.cosmik.collectionLink` record: "this card is in that
/// collection". Semble's indexer resolves both strong refs before it accepts
/// the link, so the card and collection records must already exist in the
/// repository when this is written (see `SembleLibrary.save`).
public struct CollectionLinkRecord: Codable, Equatable, Sendable {
    /// The record's lexicon NSID (`$type`), e.g. `network.cosmik.collectionLink`.
    public var recordType: String
    public var collection: StrongRef
    public var card: StrongRef
    /// DID of the user adding the card. For our own repository that is
    /// always the signed-in user.
    public var addedBy: String
    /// When the card was added to the collection; Semble uses this as the
    /// link's timestamp in the UI.
    public var addedAt: Date
    public var createdAt: Date

    public init(
        collection: StrongRef,
        card: StrongRef,
        addedBy: String,
        addedAt: Date,
        createdAt: Date,
        configuration: SembleConfiguration = .production
    ) {
        self.recordType = configuration.collectionLinkCollection
        self.collection = collection
        self.card = card
        self.addedBy = addedBy
        self.addedAt = addedAt
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case recordType = "$type"
        case collection, card, addedBy, addedAt, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordType = try container.decode(String.self, forKey: .recordType)
        collection = try container.decode(StrongRef.self, forKey: .collection)
        card = try container.decode(StrongRef.self, forKey: .card)
        addedBy = try container.decode(String.self, forKey: .addedBy)
        addedAt = try container.decodeATProtoDate(forKey: .addedAt)
        createdAt = try container.decodeATProtoDate(forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordType, forKey: .recordType)
        try container.encode(collection, forKey: .collection)
        try container.encode(card, forKey: .card)
        try container.encode(addedBy, forKey: .addedBy)
        try container.encodeATProtoDate(addedAt, forKey: .addedAt)
        try container.encodeATProtoDate(createdAt, forKey: .createdAt)
    }
}
