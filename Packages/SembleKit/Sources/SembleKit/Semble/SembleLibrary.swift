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
    /// `network.cosmik.card`'s `noteContent.text` `maxLength`, in UTF-8 bytes
    /// (cosmik-network/semble, src/modules/atproto/infrastructure/lexicons/card.json).
    private static let noteMaxLength = 10_000

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
            case .orderedSame: return lhs.id < rhs.id
            }
        }
    }

    // MARK: - Saving

    /// Writes `pending`'s new collections, card, note and collection links,
    /// in that order, using the rkeys it was created with. Every write goes
    /// through `createIdempotently`, so calling this more than once for the
    /// same `PendingSave` — a retry, a drain racing a retry, two drains
    /// racing each other — writes each record at most once. New collections
    /// go first because the links need their strong refs, exactly like the
    /// card needs to exist before anything links to it.
    public func save(_ pending: PendingSave) async throws -> SaveResult {
        guard let scheme = pending.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw SembleLibraryError.unsupportedURL(pending.url)
        }

        let noteText = pending.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let noteText, noteText.utf8.count > Self.noteMaxLength {
            throw SembleLibraryError.noteTooLong
        }

        let timestamp = pending.savedAt

        // 1. Any collections this save creates. Two saves can carry the same
        // `PendingCollection` (same rkey) if it was picked in a second sheet
        // before the first synced; `createIdempotently` means whichever
        // reaches the PDS first writes it and the other adopts it.
        var newCollectionRefs: [String: StrongRef] = [:]
        for newCollection in pending.newCollections {
            let record = CollectionRecord(
                name: newCollection.name,
                description: nil,
                accessType: newCollection.accessType,
                collaborators: [],
                createdAt: newCollection.createdAt,
                updatedAt: newCollection.createdAt,
                configuration: configuration
            )
            let ref = try await createIdempotently(collection: configuration.collectionCollection, record: record, rkey: newCollection.rkey)
            newCollectionRefs[newCollection.uri(did: pending.did, configuration: configuration)] = ref
        }

        // 2. The URL card. Everything else points at it.
        let card = CardRecord.url(pending.url, preview: pending.preview, createdAt: timestamp, configuration: configuration)
        let cardRef = try await createIdempotently(collection: configuration.cardCollection, record: card, rkey: pending.cardRkey)

        // 3. The note, if there is one worth keeping.
        // ponytail: a note edited after the first (failed) attempt is
        // silently dropped — the retry reuses `noteRkey`, so an
        // already-written note is adopted as-is rather than replaced. Editing
        // a queued save's note before it syncs isn't supported yet; per-save
        // note versioning would fix that if it turns out to matter.
        var noteRef: StrongRef?
        if let noteText {
            let note = CardRecord.note(text: noteText, about: pending.url, parent: cardRef, createdAt: timestamp, configuration: configuration)
            noteRef = try await createIdempotently(collection: configuration.cardCollection, record: note, rkey: pending.noteRkey)
        }

        // 4. One link per chosen collection — existing ones, and the ones
        // just created above.
        let linkTargets = pending.collections + pending.newCollections.compactMap { newCollectionRefs[$0.uri(did: pending.did, configuration: configuration)] }
        var linkRefs: [StrongRef] = []
        if !linkTargets.isEmpty {
            let did = await store.did
            for collection in linkTargets {
                // `PendingSave.ensureLinkRkeys()` keeps this populated for
                // every selected collection, new or existing; a missing
                // entry would mean the caller mutated `collections` /
                // `newCollections` without calling it.
                guard let linkRkey = pending.linkRkeys[collection.uri] else { continue }
                let link = CollectionLinkRecord(
                    collection: collection,
                    card: cardRef,
                    addedBy: did,
                    addedAt: timestamp,
                    createdAt: timestamp,
                    configuration: configuration
                )
                let linkRef = try await createIdempotently(collection: configuration.collectionLinkCollection, record: link, rkey: linkRkey)
                linkRefs.append(linkRef)
            }
        }

        return SaveResult(card: cardRef, note: noteRef, collectionLinks: linkRefs)
    }

    /// Creates `record` at `rkey`, or — if the PDS rejects it, which is what
    /// happens on a repeat attempt, though the reference PDS doesn't
    /// reliably say "already exists" rather than some other server error —
    /// fetches whatever is already at that key and adopts it. A connectivity
    /// failure (not a `server` error) is rethrown directly: there's nothing
    /// at `rkey` to adopt yet.
    private func createIdempotently<R: Encodable & Decodable>(collection: String, record: R, rkey: String) async throws -> StrongRef {
        do {
            return try await store.createRecord(collection: collection, record: record, rkey: rkey)
        } catch let error as XRPCError {
            guard case .server = error else { throw error }
            if let existing: RecordEnvelope<R> = try? await store.getRecord(collection: collection, rkey: rkey) {
                return existing.ref
            }
            throw error
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
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
