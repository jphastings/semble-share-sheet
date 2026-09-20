import Foundation

/// A `network.cosmik.card` record: the one record type Semble uses for both
/// saved URLs and the notes attached to them.
///
/// The shape follows Semble's `CardMapper`, which is what its own backend
/// writes to a PDS:
///
/// - A **URL card** carries the link inside `content` (`#urlContent`) and has
///   no top-level `url`.
/// - A **NOTE card** carries its text inside `content` (`#noteContent`), names
///   the URL it is about in the top-level `url`, and points at the URL card
///   through `parentCard`. Semble's indexer drops a note it can't attach to a
///   parent, so `parentCard` is effectively required.
///
/// The JSON key for the record's lexicon type is `$type`, which is why the
/// Swift property is `recordType`: the card's own `type` ("URL"/"NOTE") is a
/// different field.
public struct CardRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case url = "URL"
        case note = "NOTE"
    }

    /// `network.cosmik.card#urlMetadata`. Every field is optional; whatever
    /// the metadata endpoint knew is passed through so the AppView can render
    /// a preview before it crawls the page itself.
    public struct URLMetadata: Codable, Equatable, Sendable {
        public var recordType: String
        public var title: String?
        public var description: String?
        public var author: String?
        /// RFC-3339, passed through verbatim from the metadata endpoint.
        public var publishedDate: String?
        public var siteName: String?
        public var imageUrl: String?
        public var type: String?
        /// RFC-3339: when the metadata was fetched.
        public var retrievedAt: String?
        public var doi: String?
        public var isbn: String?

        public init(
            recordType: String,
            title: String? = nil,
            description: String? = nil,
            author: String? = nil,
            publishedDate: String? = nil,
            siteName: String? = nil,
            imageUrl: String? = nil,
            type: String? = nil,
            retrievedAt: String? = nil,
            doi: String? = nil,
            isbn: String? = nil
        ) {
            self.recordType = recordType
            self.title = title
            self.description = description
            self.author = author
            self.publishedDate = publishedDate
            self.siteName = siteName
            self.imageUrl = imageUrl
            self.type = type
            self.retrievedAt = retrievedAt
            self.doi = doi
            self.isbn = isbn
        }

        enum CodingKeys: String, CodingKey {
            case recordType = "$type"
            case title, description, author, publishedDate, siteName, imageUrl, type, retrievedAt, doi, isbn
        }
    }

    /// `network.cosmik.card#urlContent`.
    public struct URLContent: Codable, Equatable, Sendable {
        public var recordType: String
        public var url: String
        public var metadata: URLMetadata?

        public init(recordType: String, url: String, metadata: URLMetadata? = nil) {
            self.recordType = recordType
            self.url = url
            self.metadata = metadata
        }

        enum CodingKeys: String, CodingKey {
            case recordType = "$type"
            case url, metadata
        }
    }

    /// `network.cosmik.card#noteContent`.
    public struct NoteContent: Codable, Equatable, Sendable {
        public var recordType: String
        public var text: String

        public init(recordType: String, text: String) {
            self.recordType = recordType
            self.text = text
        }

        enum CodingKeys: String, CodingKey {
            case recordType = "$type"
            case text
        }
    }

    /// The lexicon union `#urlContent | #noteContent`, discriminated by the
    /// nested object's own `$type`.
    public enum Content: Codable, Equatable, Sendable {
        case url(URLContent)
        case note(NoteContent)

        private enum TypeKey: String, CodingKey {
            case type = "$type"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TypeKey.self)
            let type = try container.decode(String.self, forKey: .type)
            // Match on the fragment only: the namespace is configurable.
            if type.hasSuffix("#urlContent") {
                self = try .url(URLContent(from: decoder))
            } else if type.hasSuffix("#noteContent") {
                self = try .note(NoteContent(from: decoder))
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown card content type \"\(type)\""
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case let .url(content):
                try content.encode(to: encoder)
            case let .note(content):
                try content.encode(to: encoder)
            }
        }
    }

    /// The record's lexicon NSID (`$type`), e.g. `network.cosmik.card`.
    public var recordType: String
    public var type: Kind
    public var content: Content
    /// For NOTE cards: the URL the note is about. Always `nil` for URL cards,
    /// whose URL lives in `content`.
    public var url: String?
    /// For NOTE cards: the URL card this note belongs to.
    public var parentCard: StrongRef?
    public var createdAt: Date

    public init(
        recordType: String,
        type: Kind,
        content: Content,
        url: String? = nil,
        parentCard: StrongRef? = nil,
        createdAt: Date
    ) {
        self.recordType = recordType
        self.type = type
        self.content = content
        self.url = url
        self.parentCard = parentCard
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case recordType = "$type"
        case type, content, url, parentCard, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordType = try container.decode(String.self, forKey: .recordType)
        type = try container.decode(Kind.self, forKey: .type)
        content = try container.decode(Content.self, forKey: .content)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        parentCard = try container.decodeIfPresent(StrongRef.self, forKey: .parentCard)
        createdAt = try container.decodeATProtoDate(forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordType, forKey: .recordType)
        try container.encode(type, forKey: .type)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(parentCard, forKey: .parentCard)
        try container.encodeATProtoDate(createdAt, forKey: .createdAt)
    }
}

extension CardRecord {
    /// A URL card. When a `preview` is available it is written into the
    /// content's `metadata` so Semble can show the title and image straight
    /// away; without one the AppView fetches its own.
    public static func url(
        _ url: URL,
        preview: URLPreview? = nil,
        createdAt: Date = Date(),
        configuration: SembleConfiguration = .production
    ) -> CardRecord {
        var metadata: URLMetadata?
        if let preview {
            metadata = URLMetadata(
                recordType: configuration.urlMetadataType,
                title: preview.title,
                description: preview.description,
                siteName: preview.siteName,
                imageUrl: preview.imageURL?.absoluteString,
                type: preview.type,
                retrievedAt: ATProtoDateFormatter.string(from: createdAt)
            )
        }
        let content = URLContent(
            recordType: configuration.urlContentType,
            url: url.absoluteString,
            metadata: metadata
        )
        return CardRecord(
            recordType: configuration.cardCollection,
            type: .url,
            content: .url(content),
            url: nil,
            parentCard: nil,
            createdAt: createdAt
        )
    }

    /// A NOTE card attached to the URL card `parent`.
    public static func note(
        text: String,
        about url: URL,
        parent: StrongRef,
        createdAt: Date = Date(),
        configuration: SembleConfiguration = .production
    ) -> CardRecord {
        let content = NoteContent(recordType: configuration.noteContentType, text: text)
        return CardRecord(
            recordType: configuration.cardCollection,
            type: .note,
            content: .note(content),
            url: url.absoluteString,
            parentCard: parent,
            createdAt: createdAt
        )
    }
}
