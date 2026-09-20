import Foundation
import Combine

/// The state machine behind the "Add to Semble" share sheet, with no UI or
/// platform code so it runs (and is tested) under `swift test` on macOS.
///
/// Lifecycle: create it with the shared URL, call `load()` once, let the user
/// pick collections and type a note, then `save()`. Metadata (title, image)
/// is a nicety: if it fails the sheet still saves the bare URL.
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

    /// The URL being saved, or `nil` when the host shared nothing usable.
    public let url: URL?

    private let library: (any Library)?
    private let metadata: MetadataLoader

    /// Set once collections have been fetched successfully; from then on a
    /// failure means a *save* failed and the form stays available for retry.
    public private(set) var hasLoaded = false

    private enum FailedStep {
        case load
        case save
    }

    private var failedStep: FailedStep = .load

    /// - Parameters:
    ///   - library: The signed-in user's Semble library, or `nil` when there is
    ///     no session (the sheet then shows `Phase.notSignedIn`).
    ///   - metadata: Fetches a `URLPreview`; failures are swallowed.
    ///   - url: The shared URL, or `nil` when none could be found.
    public init(library: (any Library)?, metadata: @escaping MetadataLoader, url: URL?) {
        self.library = library
        self.metadata = metadata
        self.url = url
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
    /// picker should offer a "Create new collection" row.
    public var canCreateCollection: Bool {
        guard library != nil, hasLoaded, !isCreatingCollection else { return false }
        let name = creationName
        guard !name.isEmpty else { return false }
        return !collections.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// True when the form should be shown (as opposed to a full-screen status).
    public var showsForm: Bool {
        switch phase {
        case .ready, .saving, .saved:
            return true
        case .failed:
            return hasLoaded
        case .loading, .notSignedIn, .noURL:
            return false
        }
    }

    /// True when tapping "Add to Semble" would do something.
    public var canSave: Bool {
        guard library != nil, url != nil, hasLoaded else { return false }
        switch phase {
        case .ready:
            return true
        case .failed:
            return failedStep == .save
        case .loading, .saving, .saved, .notSignedIn, .noURL:
            return false
        }
    }

    // MARK: Actions

    /// Fetches the user's collections and the URL preview. Safe to call again
    /// after a load failure.
    public func load() async {
        guard let library else {
            phase = .notSignedIn
            return
        }
        guard let url else {
            phase = .noURL
            return
        }
        phase = .loading

        // Preview and collections are independent; run them together. The
        // preview is best-effort and never fails the load.
        let metadata = self.metadata
        let previewTask = Task { () -> URLPreview? in
            try? await metadata(url)
        }

        do {
            let fetched = try await library.myCollections()
            collections = fetched
            hasLoaded = true
        } catch {
            preview = await previewTask.value
            failedStep = .load
            phase = .failed(error.localizedDescription)
            return
        }

        preview = await previewTask.value
        phase = .ready
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

    /// Writes the card (plus note and collection links) to the user's PDS.
    /// No-op unless `canSave`. On failure the form stays editable and
    /// `save()` can simply be called again.
    public func save() async {
        guard canSave, let library, let url else { return }
        phase = .saving

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = SaveRequest(
            url: url,
            preview: preview,
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            collections: selectedCollections.map(\.ref)
        )

        do {
            _ = try await library.save(request)
            phase = .saved
        } catch {
            failedStep = .save
            phase = .failed(error.localizedDescription)
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
