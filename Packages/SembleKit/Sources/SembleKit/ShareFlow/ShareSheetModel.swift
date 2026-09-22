import Foundation
import Combine

/// The state machine behind the "Add to Semble" share sheet, with no UI or
/// platform code so it runs (and is tested) under `swift test` on macOS.
///
/// Lifecycle: create it with the shared URL, call `load()` once, let the user
/// pick collections and type a note, then `save()`. Metadata (title, image)
/// is a nicety: if it fails the sheet still saves the bare URL, and it never
/// holds up `.ready` — `preview` is filled in whenever it arrives. A URL that
/// isn't safe to send to Semble's metadata endpoint without asking (see
/// `previewAwaitingConfirmation`) isn't fetched until `loadPreview()` is
/// called.
@MainActor
public final class ShareSheetModel: ObservableObject {
    /// Which screen the sheet should show.
    public enum Phase: Equatable, Sendable {
        /// Fetching collections and the URL preview.
        case loading
        /// Everything loaded; the form is editable.
        case ready
        /// `save()` is in flight.
        case saving
        /// The save succeeded; the host should dismiss shortly.
        case saved
        /// The device (or the PDS) couldn't be reached; the save is queued
        /// on disk and will go out the next time something drains the queue.
        /// The host dismisses this the same way it dismisses `.saved`.
        case queued
        /// Loading or saving failed. The message is user-presentable.
        case failed(String)
        /// No `Session` was found; the user has to sign in through the app.
        case notSignedIn
        /// The host app shared nothing we can turn into a web URL.
        case noURL
    }

    /// Fetches a preview for a URL. A closure rather than `URLMetadataClient`
    /// so tests and previews need no network.
    public typealias MetadataLoader = @Sendable (URL) async throws -> URLPreview

    // MARK: State

    @Published public private(set) var phase: Phase = .loading
    @Published public private(set) var preview: URLPreview?
    /// True when the URL needs the user's explicit go-ahead before its
    /// preview is requested (it carries a query, fragment or userinfo that
    /// could be a secret) and that hasn't happened yet. Call `loadPreview()`.
    @Published public private(set) var previewAwaitingConfirmation = false
    /// True while a preview fetch — automatic or via `loadPreview()` — is in flight.
    @Published public private(set) var isLoadingPreview = false
    @Published public private(set) var collections: [CollectionSummary] = []
    /// URIs of the collections the card will be added to.
    @Published public var selected: Set<String> = []
    /// The collection picker's search / create text.
    @Published public var query: String = ""
    /// Free text saved as a `NOTE` card attached to the URL card. Whitespace-only is ignored.
    @Published public var note: String = ""
    /// True while `createCollection()` is in flight.
    @Published public private(set) var isCreatingCollection = false
    /// A user-presentable message when creating a collection failed. Cleared on the next attempt.
    @Published public private(set) var collectionError: String?
    /// True once a collections refresh has failed and the picker is showing
    /// stale (or empty) data. Creating a collection needs a live PDS
    /// round-trip, so it's disabled until the next successful refresh.
    @Published public private(set) var collectionsRefreshFailed = false

    /// The URL being saved, or `nil` when the host shared nothing usable.
    public let url: URL?

    private let library: (any Library)?
    private let metadata: MetadataLoader
    private let did: String?
    private let queue: SaveQueue
    private let collectionsCache: CollectionsCache?

    /// Set once collections have been fetched successfully; from then on a
    /// failure means a *save* failed and the form stays available for retry.
    public private(set) var hasLoaded = false

    private enum FailedStep {
        case load
        case save
    }

    private var failedStep: FailedStep = .load

    /// The save in progress, kept across attempts so a retry after a
    /// permanent failure reuses the same id and rkeys — the point of which
    /// is that repeating the write is safe — rather than starting a fresh
    /// one every tap.
    private var pendingSave: PendingSave?

    /// - Parameters:
    ///   - library: The signed-in user's Semble library, or `nil` when there is
    ///     no session (the sheet then shows `Phase.notSignedIn`).
    ///   - metadata: Fetches a `URLPreview`; failures are swallowed.
    ///   - url: The shared URL, or `nil` when none could be found.
    ///   - did: The signed-in user's DID, so a save can be queued against it. `nil` alongside `library == nil`.
    ///   - queue: Where a save that can't reach the PDS right away is kept until something drains it.
    ///   - collectionsCache: Shows a cached collection list before (or instead of) a network fetch. `nil` skips caching.
    public init(
        library: (any Library)?,
        metadata: @escaping MetadataLoader,
        url: URL?,
        did: String?,
        queue: SaveQueue,
        collectionsCache: CollectionsCache? = nil
    ) {
        self.library = library
        self.metadata = metadata
        self.url = url
        self.did = did
        self.queue = queue
        self.collectionsCache = collectionsCache
    }

    // MARK: Derived state

    /// The host of the shared URL without a leading "www.", for the preview header.
    public var domain: String? {
        guard let host = url?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The query with surrounding whitespace removed; also the name a new collection would get.
    public var creationName: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collections matching the query (all of them when the query is blank).
    public var visibleCollections: [CollectionSummary] {
        let needle = creationName
        guard !needle.isEmpty else { return collections }
        return collections.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    /// The collections currently ticked, in display order.
    public var selectedCollections: [CollectionSummary] {
        collections.filter { selected.contains($0.id) }
    }

    /// True when the query names a collection that doesn't exist yet, so the
    /// picker should offer a "Create new collection" row. Offline collection
    /// creation isn't supported, so this is also `false` whenever the last
    /// refresh failed (the list on screen may be stale or empty).
    public var canCreateCollection: Bool {
        guard library != nil, hasLoaded, !isCreatingCollection, !collectionsRefreshFailed else { return false }
        let name = creationName
        guard !name.isEmpty else { return false }
        return !collections.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// True when the form should be shown (as opposed to a full-screen status).
    public var showsForm: Bool {
        switch phase {
        case .ready, .saving, .saved, .queued:
            return true
        case .failed:
            return hasLoaded
        case .loading, .notSignedIn, .noURL:
            return false
        }
    }

    /// True when tapping "Add to Semble" would do something.
    public var canSave: Bool {
        guard library != nil, url != nil, did != nil, hasLoaded else { return false }
        switch phase {
        case .ready:
            return true
        case .failed:
            return failedStep == .save
        case .loading, .saving, .saved, .queued, .notSignedIn, .noURL:
            return false
        }
    }

    // MARK: Actions

    /// Fetches the user's collections and, for URLs safe to preview without
    /// asking first, the URL preview. Safe to call again after a load
    /// failure. If a cached collection list exists it's shown immediately
    /// (`.ready` straight away) while the network fetch replaces it in the
    /// background; a transient refresh failure leaves the cache (or an empty
    /// list, offline with nothing cached) on screen rather than failing the
    /// whole sheet — saving without collections has to work offline. The
    /// preview (when it isn't waiting on `loadPreview()`) is filled in
    /// independently and never delays this.
    public func load() async {
        guard let library else {
            phase = .notSignedIn
            return
        }
        guard let url else {
            phase = .noURL
            return
        }

        if let did, let cached = collectionsCache?.load(for: did) {
            collections = cached
            hasLoaded = true
            phase = .ready
        } else {
            phase = .loading
        }

        if url.isSafeToPreviewAutomatically {
            fetchPreview(for: url)
        } else {
            previewAwaitingConfirmation = true
        }

        do {
            let fetched = try await library.myCollections()
            collections = fetched
            hasLoaded = true
            collectionsRefreshFailed = false
            if let did {
                collectionsCache?.save(fetched, for: did)
            }
            phase = .ready
        } catch {
            collectionsRefreshFailed = true
            if hasLoaded {
                // Already showing something usable (cache, or an earlier
                // successful load); a refresh failure doesn't take that away.
                return
            }
            guard isPermanentFailure(error) else {
                // Nothing cached and the network is the problem, not the
                // request: still usable, just with an empty picker.
                hasLoaded = true
                phase = .ready
                return
            }
            failedStep = .load
            phase = .failed(error.localizedDescription)
        }
    }

    /// Fetches the preview for a URL that needed confirmation first. No-op if
    /// it's already loading, already loaded, or never needed confirmation.
    public func loadPreview() {
        guard previewAwaitingConfirmation, let url else { return }
        previewAwaitingConfirmation = false
        fetchPreview(for: url)
    }

    /// Kicks off a best-effort preview fetch in the background; `preview`
    /// (and `isLoadingPreview`) update whenever it resolves, whether or not
    /// the sheet has since moved on to saving.
    private func fetchPreview(for url: URL) {
        isLoadingPreview = true
        let metadata = self.metadata
        Task {
            preview = try? await metadata(url)
            isLoadingPreview = false
        }
    }

    /// Adds or removes a collection from the selection.
    public func toggle(_ collection: CollectionSummary) {
        toggle(uri: collection.id)
    }

    /// Adds or removes a collection (by URI) from the selection.
    public func toggle(uri: String) {
        if selected.contains(uri) {
            selected.remove(uri)
        } else {
            selected.insert(uri)
        }
    }

    /// Creates a closed collection named after the current query, selects it,
    /// and clears the query. No-op unless `canCreateCollection`.
    public func createCollection() async {
        guard let library, canCreateCollection else { return }
        let name = creationName
        isCreatingCollection = true
        collectionError = nil
        defer { isCreatingCollection = false }

        do {
            let created = try await library.createCollection(named: name, accessType: .closed)
            collections.insert(created, at: 0)
            selected.insert(created.id)
            query = ""
        } catch {
            collectionError = error.localizedDescription
        }
    }

    /// Builds (or updates) the pending save, enqueues it, and tries to write
    /// it right away — claiming it exactly like any other drain would. No-op
    /// unless `canSave`.
    ///
    /// - A reachable PDS: `.saved`, and the queued file is gone.
    /// - Unreachable (or a 401/429/5xx): `.queued`; the item stays on disk
    ///   for the next drain and the host dismisses the sheet regardless.
    /// - A permanent failure (bad URL, note too long, a 4xx that isn't a
    ///   session problem): `.failed`, and the item is removed from the queue
    ///   — the user is looking at the message right here and a retry
    ///   re-enqueues the same `PendingSave`.
    public func save() async {
        guard canSave, let library, let url, let did else { return }
        phase = .saving

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteText = trimmedNote.isEmpty ? nil : trimmedNote
        let collectionRefs = selectedCollections.map(\.ref)

        var pending = pendingSave ?? PendingSave(did: did, url: url, preview: preview, note: noteText, collections: collectionRefs)
        pending.note = noteText
        pending.collections = collectionRefs
        pending.ensureLinkRkeys()
        pendingSave = pending

        do {
            try queue.enqueue(pending)
        } catch {
            // ponytail: a queue write failure (disk full, no space left) is
            // reported like any other save failure rather than retried —
            // there's no fallback path for "couldn't even get it onto disk".
            failedStep = .save
            phase = .failed(error.localizedDescription)
            return
        }

        switch await queue.attempt(pending, using: library) {
        case .saved:
            pendingSave = nil
            phase = .saved
        case .queued:
            phase = .queued
        case let .failed(message):
            queue.remove(pending.id)
            failedStep = .save
            phase = .failed(message)
        }
    }

    /// Re-runs whichever step last failed. Does nothing unless `phase` is `.failed`.
    public func retry() async {
        guard case .failed = phase else { return }
        switch failedStep {
        case .load:
            await load()
        case .save:
            await save()
        }
    }
}
