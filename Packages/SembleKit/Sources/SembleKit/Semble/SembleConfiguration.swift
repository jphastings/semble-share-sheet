import Foundation

/// Where Semble lives: the record collections (lexicon NSIDs) it indexes from
/// the firehose, its public API and its website.
///
/// Semble's backend derives every `$type` it writes from a configurable base
/// namespace (`network.cosmik` in production), so this does the same: the
/// content-union types (`#urlContent`, `#noteContent`, `#urlMetadata`) hang
/// off `cardCollection` rather than being hard-coded, which keeps a staging
/// namespace one value away.
public struct SembleConfiguration: Equatable, Sendable {
    /// NSID of the card record collection, e.g. `network.cosmik.card`.
    public var cardCollection: String
    /// NSID of the collection record collection, e.g. `network.cosmik.collection`.
    public var collectionCollection: String
    /// NSID of the card-to-collection link collection, e.g. `network.cosmik.collectionLink`.
    public var collectionLinkCollection: String
    /// Semble's public XRPC API, e.g. `https://api.semble.so/xrpc`.
    public var apiBaseURL: URL
    /// Semble's website, for "open in Semble" links, e.g. `https://semble.so`.
    public var websiteURL: URL

    public init(
        cardCollection: String,
        collectionCollection: String,
        collectionLinkCollection: String,
        apiBaseURL: URL,
        websiteURL: URL
    ) {
        self.cardCollection = cardCollection
        self.collectionCollection = collectionCollection
        self.collectionLinkCollection = collectionLinkCollection
        self.apiBaseURL = apiBaseURL
        self.websiteURL = websiteURL
    }

    public static let production = SembleConfiguration(
        cardCollection: "network.cosmik.card",
        collectionCollection: "network.cosmik.collection",
        collectionLinkCollection: "network.cosmik.collectionLink",
        apiBaseURL: URL(string: "https://api.semble.so/xrpc")!,
        websiteURL: URL(string: "https://semble.so")!
    )

    /// `$type` of a card's `content` when the card is a URL.
    public var urlContentType: String { cardCollection + "#urlContent" }
    /// `$type` of a card's `content` when the card is a note.
    public var noteContentType: String { cardCollection + "#noteContent" }
    /// `$type` of the metadata object nested in URL content.
    public var urlMetadataType: String { cardCollection + "#urlMetadata" }
}
