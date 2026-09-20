import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A plain HTTP request. Deliberately minimal so tests can stub the network
/// without touching `URLSession`.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// A `POST` with an `application/x-www-form-urlencoded` body.
    public static func form(url: URL, fields: [String: String], headers: [String: String] = [:]) -> HTTPRequest {
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/x-www-form-urlencoded"
        return HTTPRequest(method: "POST", url: url, headers: allHeaders, body: Data(fields.formURLEncoded.utf8))
    }

    /// A `POST` with a JSON body.
    public static func json(url: URL, body: Data, headers: [String: String] = [:]) -> HTTPRequest {
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/json"
        return HTTPRequest(method: "POST", url: url, headers: allHeaders, body: body)
    }
}

/// The response to an `HTTPRequest`. Header names are lower-cased so lookups
/// are case-insensitive, as HTTP requires.
public struct HTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }

    public var isSuccess: Bool { (200 ..< 300).contains(statusCode) }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public func decode<T: Decodable>(_ type: T.Type = T.self, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(T.self, from: body)
    }
}

/// The one seam between SembleKit and the network. Production code uses
/// `URLSessionHTTPClient`; tests use a stub.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name] = value
            }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

extension Dictionary where Key == String, Value == String {
    /// Encodes the dictionary as `application/x-www-form-urlencoded`, with keys
    /// sorted so the output is deterministic (and therefore testable).
    var formURLEncoded: String {
        map { key, value in "\(key.formURLEncodedComponent)=\(value.formURLEncodedComponent)" }
            .sorted()
            .joined(separator: "&")
    }
}

extension String {
    var formURLEncodedComponent: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
