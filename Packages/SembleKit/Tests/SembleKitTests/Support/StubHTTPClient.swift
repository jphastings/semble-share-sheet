import Foundation
@testable import SembleKit

/// Records every request and answers each one from a queue of handlers, so a
/// test can script a whole exchange ("first the PAR call fails with
/// `use_dpop_nonce`, then it succeeds") and assert on what was sent.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    typealias Handler = (HTTPRequest) throws -> HTTPResponse

    private let lock = NSLock()
    private(set) var requests: [HTTPRequest] = []
    private var routes: [(matches: (HTTPRequest) -> Bool, handler: Handler)] = []

    /// Answers requests whose URL starts with `prefix` (query string ignored).
    func on(_ prefix: String, method: String? = nil, _ handler: @escaping Handler) {
        lock.withLock {
            routes.append((
                matches: { request in
                    (method == nil || request.method == method) && request.url.absoluteString.hasPrefix(prefix)
                },
                handler: handler
            ))
        }
    }

    /// Answers requests matching `prefix` with a JSON body.
    func on(_ prefix: String, method: String? = nil, status: Int = 200, headers: [String: String] = [:], json: String) {
        on(prefix, method: method) { _ in
            HTTPResponse(statusCode: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, body: Data(json.utf8))
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let handler: Handler? = lock.withLock {
            requests.append(request)
            // Later registrations win, so a test can override a default.
            return routes.last(where: { $0.matches(request) })?.handler
        }
        guard let handler else {
            throw StubHTTPClientError.unexpectedRequest(request.method, request.url.absoluteString)
        }
        return try handler(request)
    }

    var lastRequest: HTTPRequest? { lock.withLock { requests.last } }
}

enum StubHTTPClientError: Error, CustomStringConvertible {
    case unexpectedRequest(String, String)

    var description: String {
        switch self {
        case let .unexpectedRequest(method, url): "Unexpected request: \(method) \(url)"
        }
    }
}
