import Foundation

/// The "save a URL to Semble" workflow, written straight into the user's PDS.
///
/// Nothing here talks to Semble's servers: records go into the user's own
/// repository and Semble's AppView picks them up from the firehose. That means
/// write order matters. The indexer resolves a note's `parentCard` and a
/// link's `card`/`collection` refs when it sees them, so the card is always
/// written first, then the note, then the links.
public actor SembleLibrary: Library {
    private let store: RecordStore
    private let configuration: SembleConfiguration
    private let now: @Sendable () -> Date

    /// Page size for `listRecords`; 100 is the XRPC maximum.
    private static let collectionPageSize = 100
    /// Stops a misbehaving PDS (a cursor that never ends) from looping
    /// forever. 20 pages is 2,000 collections; nobody has that many.
    private static let maxCollectionPages = 20

    public init(pds: PDSClient, configuration: SembleConfiguration = .production) {
        self.store = pds
        self.configuration = configuration
        self.now = { Date() }
    }

    /// For tests: any `RecordStore`, and a clock.
    init(
        store: RecordStore,
        configuration: SembleConfiguration = .production,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.configuration = configuration
        self.now = now
    }

    // MARK: - Collections

    public func myCollections() async throws -> [CollectionSummary] {
        var summaries: [CollectionSummary] = []
        var cursor: String?

        for _ in 0 ..< Self.maxCollectionPages {
            let page: RecordPage<CollectionListing> = try await store.listRecords(
                collection: configuration.collectionCollection,
                limit: Self.collectionPageSize,
                cursor: cursor
            )
            for envelope in page.records {
                // A collection without a name can't be shown or chosen. Other
                // clients may write ones we don't understand; skip, don't fail.
                guard let name = envelope.value.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty
                else { continue }
                summaries.append(CollectionSummary(
                    ref: StrongRef(uri: envelope.uri, cid: envelope.cid),
                    name: name,
                    accessType: envelope.value.accessType.flatMap { CollectionAccessType(rawValue: $0) } ?? .closed,
                    description: envelope.value.description
                ))
            }
            guard let next = page.cursor, !next.isEmpty, !page.records.isEmpty else { break }
            cursor = next
        }

        return summaries.sorted { lhs, rhs in
            switch lhs.name.localizedCaseInsensitiveCompare(rhs.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.ref.uri < rhs.ref.uri
            }
        }
    }

    public func createCollection(named name: String, accessType: CollectionAccessType) async throws -> CollectionSummary {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw SembleLibraryError.emptyCollectionName }

        let timestamp = now()
        let record = CollectionRecord(
            name: trimmedName,
            description: nil,
            accessType: accessType,
            collaborators: [],
            createdAt: timestamp,
            updatedAt: timestamp,
            configuration: configuration
        )
        let ref = try await store.createRecord(collection: configuration.collectionCollection, record: record)
        return CollectionSummary(ref: ref, name: trimmedName, accessType: accessType, description: nil)
    }

    // MARK: - Saving

    public func save(_ request: SaveRequest) async throws -> SaveResult {
        guard let scheme = request.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw SembleLibraryError.unsupportedURL(request.url)
        }

        let timestamp = now()

        // 1. The URL card. Everything else points at it.
        let card = CardRecord.url(request.url, preview: request.preview, createdAt: timestamp, configuration: configuration)
        let cardRef = try await store.createRecord(collection: configuration.cardCollection, record: card)

        // 2. The note, if there is one worth keeping.
        var noteRef: StrongRef?
        if let text = request.note?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let note = CardRecord.note(text: text, about: request.url, parent: cardRef, createdAt: timestamp, configuration: configuration)
            noteRef = try await store.createRecord(collection: configuration.cardCollection, record: note)
        }

        // 3. One link per chosen collection.
        var linkRefs: [StrongRef] = []
        if !request.collections.isEmpty {
            let did = await store.did
            for collection in request.collections {
                let link = CollectionLinkRecord(
                    collection: collection,
                    card: cardRef,
                    addedBy: did,
                    addedAt: timestamp,
                    createdAt: timestamp,
                    configuration: configuration
                )
                let linkRef = try await store.createRecord(collection: configuration.collectionLinkCollection, record: link)
                linkRefs.append(linkRef)
            }
        }

        return SaveResult(card: cardRef, note: noteRef, collectionLinks: linkRefs)
    }
}

/// The few fields of a `network.cosmik.collection` record the picker needs,
/// all optional. Decoding the full `CollectionRecord` would reject any
/// collection another client wrote with, say, a missing timestamp, and one
/// odd record shouldn't empty the whole picker.
private struct CollectionListing: Decodable, Sendable {
    var name: String?
    var description: String?
    var accessType: String?
}
