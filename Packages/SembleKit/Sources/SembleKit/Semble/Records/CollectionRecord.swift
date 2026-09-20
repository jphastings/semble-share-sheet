import Foundation

/// A `network.cosmik.collection` record, as Semble's `CollectionMapper`
/// writes it. Only `name` and `accessType` are required by the lexicon, but
/// Semble always writes the timestamps and the (possibly empty) collaborator
/// list, so this does too.
public struct CollectionRecord: Codable, Equatable, Sendable {
    /// The record's lexicon NSID (`$type`), e.g. `network.cosmik.collection`.
    public var recordType: String
    public var name: String
    public var description: String?
    public var accessType: CollectionAccessType
    /// DIDs allowed to add cards to a closed collection.
    public var collaborators: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        name: String,
        description: String? = nil,
        accessType: CollectionAccessType,
        collaborators: [String] = [],
        createdAt: Date,
        updatedAt: Date,
        configuration: SembleConfiguration = .production
    ) {
        self.recordType = configuration.collectionCollection
        self.name = name
        self.description = description
        self.accessType = accessType
        self.collaborators = collaborators
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case recordType = "$type"
        case name, description, accessType, collaborators, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordType = try container.decode(String.self, forKey: .recordType)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        accessType = try container.decode(CollectionAccessType.self, forKey: .accessType)
        collaborators = try container.decodeIfPresent([String].self, forKey: .collaborators) ?? []
        createdAt = try container.decodeATProtoDate(forKey: .createdAt)
        updatedAt = try container.decodeATProtoDate(forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordType, forKey: .recordType)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(accessType, forKey: .accessType)
        try container.encode(collaborators, forKey: .collaborators)
        try container.encodeATProtoDate(createdAt, forKey: .createdAt)
        try container.encodeATProtoDate(updatedAt, forKey: .updatedAt)
    }
}
