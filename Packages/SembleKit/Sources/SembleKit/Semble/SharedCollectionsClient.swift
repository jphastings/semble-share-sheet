import Foundation

/// Open collections owned by other people, which anyone may add cards to.
///
/// Listing and searching use Semble's public, unauthenticated API; neither
/// returns a cid, which a `CollectionLinkRecord`'s strong ref needs, so
/// `ref(for:)` reads the collection record straight from its owner's PDS.
/// Nothing here ever carries the user's tokens: these are plain requests to
/// hosts other than the user's own PDS.
public struct SharedCollectionsClient: Sendable {
    /// Semble's own page-size cap.
    private static let pageSize = 100

    private let configuration: SembleConfiguration
    private let http: HTTPClient

    public init(configuration: SembleConfiguration = .production, http: HTTPClient = URLSessionHTTPClient()) {
        self.configuration = configuration
        self.http = http
    }

    /// Open collections `did` has added cards to but doesn't own, most
    /// recently added to first. Each comes without a ref; see `ref(for:)`.
    // ponytail: first page only (100 collections); follow `hasMore` if anyone contributes to more.
    public func contributed(by did: String) async throws -> [CollectionSummary] {
        try await collections("network.cosmik.collection.listContributed", query: [
            "identifier": did,
            "limit": String(Self.pageSize),
        ])
    }

    /// Open collections matching `text`, anyone's (the user's own included).
    public func search(_ text: String) async throws -> [CollectionSummary] {
        try await collections("network.cosmik.collection.search", query: [
            "searchText": text,
            "accessType": CollectionAccessType.open.rawValue,
            "limit": String(Self.pageSize),
        ])
    }

    /// The strong ref for the collection at `uri`, read unauthenticated from
    /// its owner's PDS.
    public func ref(for uri: String) async throws -> StrongRef {
        guard let atURI = ATURI(uri) else { throw SharedCollectionsError.unavailable }
        let owner = try await IdentityResolver(http: http).resolve(atURI.did)
        guard owner.pdsURL.scheme == "https" else { throw SharedCollectionsError.unavailable }
        let endpoint = owner.pdsURL.appendingPathComponent("xrpc/com.atproto.repo.getRecord")
        let record: StrongRef = try await get(endpoint, query: [
            "repo": atURI.did,
            "collection": atURI.collection,
            "rkey": atURI.rkey,
        ])
        guard record.uri == uri else { throw SharedCollectionsError.unavailable }
        return record
    }

    private func collections(_ nsid: String, query: [String: String]) async throws -> [CollectionSummary] {
        let page: Page = try await get(configuration.apiBaseURL.appendingPathComponent(nsid), query: query, headers: [
            // Semble's usage analytics group requests by this self-declared header.
            "x-semble-client": "semble-ios-share",
        ])
        return page.collections.compactMap { $0.summary(collectionNSID: configuration.collectionCollection) }
    }

    private func get<T: Decodable>(_ endpoint: URL, query: [String: String], headers: [String: String] = [:]) async throws -> T {
        // Encoded by hand: `URLComponents` leaves `&` alone inside a query value.
        guard let url = URL(string: endpoint.absoluteString + "?" + query.formURLEncoded) else {
            throw SharedCollectionsError.unavailable
        }
        let response = try await http.send(HTTPRequest(url: url, headers: headers.merging(["Accept": "application/json"]) { a, _ in a }))
        guard response.isSuccess, let decoded = try? response.decode(T.self) else {
            throw SharedCollectionsError.unavailable
        }
        return decoded
    }

    /// `{"collections": [...], "pagination": {...}, "sorting": {...}}`, as
    /// both endpoints return it.
    private struct Page: Decodable {
        var collections: [Item]
    }

    private struct Item: Decodable {
        var uri: String?
        var name: String?
        var description: String?
        var accessType: String?
        var author: Author?

        struct Author: Decodable {
            var handle: String?
        }

        /// `nil` for anything that can't be linked to: no AT-URI (Semble's
        /// API marks it optional), not a collection record, or no name.
        func summary(collectionNSID: String) -> CollectionSummary? {
            guard let uri, ATURI(uri)?.collection == collectionNSID,
                  let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            else { return nil }
            return CollectionSummary(
                sharedURI: uri,
                name: name,
                accessType: accessType.flatMap { CollectionAccessType(rawValue: $0) } ?? .open,
                description: description,
                ownerHandle: author?.handle
            )
        }
    }
}

/// A shared collection couldn't be listed or looked up. One case, like
/// `URLMetadataError`: the share sheet carries on without it either way.
public enum SharedCollectionsError: LocalizedError, Equatable {
    case unavailable

    public var errorDescription: String? {
        "Couldn't reach that collection right now."
    }
}
