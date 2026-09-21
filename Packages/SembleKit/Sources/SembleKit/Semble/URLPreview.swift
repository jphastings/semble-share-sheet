import Foundation

/// What Semble knows about a URL: enough to show a preview in the share sheet
/// and to seed the card's `metadata`.
public struct URLPreview: Codable, Equatable, Sendable {
    public var url: URL
    public var title: String?
    public var description: String?
    public var siteName: String?
    /// Content type as Semble classifies it, e.g. `article`, `video`.
    public var type: String?
    public var imageURL: URL?

    public init(
        url: URL,
        title: String? = nil,
        description: String? = nil,
        siteName: String? = nil,
        type: String? = nil,
        imageURL: URL? = nil
    ) {
        self.url = url
        self.title = title
        self.description = description
        self.siteName = siteName
        self.type = type
        self.imageURL = imageURL
    }
}

/// The metadata lookup failed. There is deliberately only one case: the
/// preview is a nicety, the share sheet carries on without it, and no user
/// can act on the difference between a 500 and a timeout.
public enum URLMetadataError: LocalizedError, Equatable {
    case unavailable

    public var errorDescription: String? {
        "Couldn't fetch a preview for this link."
    }
}

/// Asks Semble's public `network.cosmik.card.getUrlMetadata` endpoint for a
/// URL's title, description and image. This is the only call to
/// `api.semble.so`; it needs no authentication.
public struct URLMetadataClient: Sendable {
    /// Short: the preview is best-effort and must never hold up the sheet.
    private static let timeout: TimeInterval = 5

    private let configuration: SembleConfiguration
    private let http: HTTPClient

    public init(configuration: SembleConfiguration = .production, http: HTTPClient = URLSessionHTTPClient()) {
        self.configuration = configuration
        self.http = http
    }

    public func preview(for url: URL) async throws -> URLPreview {
        let endpoint = configuration.apiBaseURL.appendingPathComponent("network.cosmik.card.getUrlMetadata")
        // Encode the query by hand: `URLComponents` leaves `&` and `?` alone
        // inside a query value, which mangles any URL that has its own query.
        guard let requestURL = URL(string: endpoint.absoluteString + "?url=" + url.absoluteString.formURLEncodedComponent) else {
            throw URLMetadataError.unavailable
        }
        let request = HTTPRequest(
            method: "GET",
            url: requestURL,
            headers: [
                "Accept": "application/json",
                // Semble's usage analytics group requests by this self-declared
                // header; it is optional and changes nothing about the response.
                "x-semble-client": "semble-ios-share",
            ],
            timeout: Self.timeout
        )

        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch {
            throw URLMetadataError.unavailable
        }
        guard response.isSuccess, let decoded = try? response.decode(Response.self) else {
            throw URLMetadataError.unavailable
        }
        return decoded.metadata.preview(requested: url)
    }

    /// `{"metadata": {...}}`, as `getUrlMetadata` returns it. `stats` and the
    /// caller-relative flags are only present for authenticated requests and
    /// are ignored.
    private struct Response: Decodable {
        var metadata: Metadata
    }

    private struct Metadata: Decodable {
        var url: String?
        var title: String?
        var description: String?
        var siteName: String?
        var imageUrl: String?
        var type: String?

        func preview(requested: URL) -> URLPreview {
            URLPreview(
                url: url.flatMap { URL(string: $0) } ?? requested,
                title: title,
                description: description,
                siteName: siteName,
                type: type,
                // Never load a thumbnail over a scheme other than https: the
                // page names it, and it's loaded unauthenticated from inside
                // the memory-capped extension.
                imageURL: imageUrl.flatMap { URL(string: $0) }.flatMap { $0.scheme == "https" ? $0 : nil }
            )
        }
    }
}

extension URL {
    /// True when the URL carries no query, fragment or userinfo (`user:pass@`)
    /// — the only case where sending the whole URL to Semble's metadata
    /// endpoint can't also send along a secret embedded in it. Anything else
    /// needs the user's explicit go-ahead first; see
    /// `ShareSheetModel.loadPreview()`.
    var isSafeToPreviewAutomatically: Bool {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return false }
        return components.user == nil
            && components.password == nil
            && (components.query ?? "").isEmpty
            && (components.fragment ?? "").isEmpty
    }
}
