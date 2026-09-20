import Foundation

/// The subset of RFC 8414 authorization server metadata that ATProto OAuth
/// needs from `/.well-known/oauth-authorization-server`.
struct AuthorizationServerMetadata: Decodable, Equatable, Sendable {
    let issuer: URL
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let pushedAuthorizationRequestEndpoint: URL

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case pushedAuthorizationRequestEndpoint = "pushed_authorization_request_endpoint"
    }
}

/// RFC 9728 protected resource metadata, served by the PDS at
/// `/.well-known/oauth-protected-resource`. It tells us which authorization
/// server(s) can mint tokens for that PDS; a big host like bsky.social runs
/// its own, a self-hosted PDS usually *is* its own.
struct ProtectedResourceMetadata: Decodable, Equatable, Sendable {
    let authorizationServers: [URL]

    enum CodingKeys: String, CodingKey {
        case authorizationServers = "authorization_servers"
    }
}

/// Fetches the two `.well-known` documents above.
struct OAuthDiscovery: Sendable {
    let http: HTTPClient

    /// The issuer of the authorization server that protects `pdsURL`.
    func authorizationServerIssuer(forPDS pdsURL: URL) async throws -> URL {
        let url = try wellKnownURL(base: pdsURL, name: "oauth-protected-resource")
        let metadata: ProtectedResourceMetadata = try await fetch(url)
        guard let issuer = metadata.authorizationServers.first else {
            throw OAuthError.invalidMetadata("\(pdsURL.hostDescription) lists no authorization server")
        }
        return issuer
    }

    /// The metadata of the authorization server at `issuer`, verified to
    /// claim the same issuer (RFC 8414 §3.3): a document that names some
    /// other server is either misconfigured or an attack.
    func metadata(forIssuer issuer: URL) async throws -> AuthorizationServerMetadata {
        let url = try wellKnownURL(base: issuer, name: "oauth-authorization-server")
        let metadata: AuthorizationServerMetadata = try await fetch(url)
        guard metadata.issuer.hasSameOrigin(as: issuer) else {
            throw OAuthError.issuerMismatch(expected: issuer.absoluteString, actual: metadata.issuer.absoluteString)
        }
        return metadata
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(url: url, headers: ["Accept": "application/json"]))
        } catch {
            throw OAuthError.discoveryFailed(url)
        }
        guard response.isSuccess else {
            throw OAuthError.discoveryFailed(url)
        }
        do {
            return try response.decode(T.self)
        } catch {
            throw OAuthError.discoveryFailed(url)
        }
    }

    /// `https://host/.well-known/<name>`. Both the PDS URL and the issuer are
    /// origins in ATProto (no path), so the well-known path replaces whatever
    /// path there was.
    private func wellKnownURL(base: URL, name: String) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw OAuthError.discoveryFailed(base)
        }
        components.path = "/.well-known/" + name
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw OAuthError.discoveryFailed(base)
        }
        return url
    }
}

extension URL {
    /// `scheme://host[:port]`, lower-cased: the key for anything that is
    /// per-server, like DPoP nonces.
    var originKey: String {
        let components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        let scheme = (components?.scheme ?? "").lowercased()
        let host = (components?.host ?? "").lowercased()
        let port = components?.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    func hasSameOrigin(as other: URL) -> Bool {
        originKey == other.originKey
    }
}
