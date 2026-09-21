import CryptoKit
import Foundation
import OAuthenticator
import XCTest
@testable import SembleKit

/// Canned identities, metadata documents and sessions shared by the ATProto
/// tests. Everything points at made-up `.example` hosts so a test that
/// accidentally escapes the stub fails loudly.
enum Fixtures {
    static let did = "did:plc:abc123xyz"
    static let handle = "alice.example.com"
    static let pdsURL = URL(string: "https://pds.example")!
    static let issuer = URL(string: "https://auth.example")!
    static let clientID = URL(string: "https://app.example/oauth-client-metadata.json")!
    static let redirectURI = URL(string: "me.byjp.semble-share:/oauth/callback")!
    static let scope = "atproto include:network.cosmik.authFull"

    static let configuration = OAuthClientConfiguration(clientID: clientID, redirectURI: redirectURI, scope: scope)

    static let parEndpoint = "https://auth.example/oauth/par"
    static let tokenEndpoint = "https://auth.example/oauth/token"
    static let authorizeEndpoint = "https://auth.example/oauth/authorize"

    static func didDocument(did: String = did, handle: String? = handle, pds: URL? = pdsURL) -> String {
        let alsoKnownAs = handle.map { "\"at://\($0)\"" } ?? ""
        let service = pds.map {
            """
            {"id": "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": "\($0.absoluteString)"}
            """
        } ?? ""
        return """
        {
          "@context": ["https://www.w3.org/ns/did/v1"],
          "id": "\(did)",
          "alsoKnownAs": [\(alsoKnownAs)],
          "verificationMethod": [{"id": "\(did)#atproto", "type": "Multikey", "controller": "\(did)", "publicKeyMultibase": "zQ3sh"}],
          "service": [\(service)]
        }
        """
    }

    static func protectedResource(issuer: URL = issuer) -> String {
        """
        {"resource": "\(pdsURL.absoluteString)", "authorization_servers": ["\(issuer.absoluteString)"], "scopes_supported": ["atproto"]}
        """
    }

    /// A complete authorization-server document: OAuthenticator's
    /// `ServerMetadata` has no optional fields, so every one must be present.
    static func authorizationServerMetadata(issuer: URL = issuer) -> String {
        """
        {
          "issuer": "\(issuer.absoluteString)",
          "authorization_endpoint": "\(authorizeEndpoint)",
          "token_endpoint": "\(tokenEndpoint)",
          "pushed_authorization_request_endpoint": "\(parEndpoint)",
          "response_types_supported": ["code"],
          "grant_types_supported": ["authorization_code", "refresh_token"],
          "code_challenge_methods_supported": ["S256"],
          "token_endpoint_auth_methods_supported": ["none", "private_key_jwt"],
          "token_endpoint_auth_signing_alg_values_supported": ["ES256"],
          "scopes_supported": ["atproto"],
          "authorization_response_iss_parameter_supported": true,
          "require_pushed_authorization_requests": true,
          "dpop_signing_alg_values_supported": ["ES256"],
          "require_request_uri_registration": true,
          "client_id_metadata_document_supported": true
        }
        """
    }

    static func serverMetadata(issuer: URL = issuer) -> ServerMetadata {
        try! JSONDecoder().decode(ServerMetadata.self, from: Data(authorizationServerMetadata(issuer: issuer).utf8))
    }

    static func tokenResponse(
        sub: String = did,
        accessToken: String = "access-1",
        refreshToken: String = "refresh-1",
        expiresIn: Int = 3600,
        scope: String = scope
    ) -> String {
        """
        {"access_token": "\(accessToken)", "refresh_token": "\(refreshToken)", "token_type": "DPoP", "expires_in": \(expiresIn), "sub": "\(sub)", "scope": "\(scope)"}
        """
    }

    /// The authorization server's "come back with this nonce" answer.
    static func useDPoPNonce(_ nonce: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 400,
            headers: ["DPoP-Nonce": nonce, "Content-Type": "application/json"],
            body: Data(#"{"error": "use_dpop_nonce", "error_description": "Authorization server requires nonce in DPoP proof"}"#.utf8)
        )
    }

    static func login(
        accessToken: String = "access-0",
        refreshToken: String = "refresh-0",
        expiry: Date? = Date().addingTimeInterval(3600)
    ) -> Login {
        Login(
            accessToken: Token(value: accessToken, expiry: expiry),
            refreshToken: Token(value: refreshToken),
            scopes: scope,
            issuingServer: issuer.absoluteString,
            additionalParams: ["did": did]
        )
    }

    static func session(
        accessToken: String = "access-0",
        refreshToken: String = "refresh-0",
        expiry: Date? = Date().addingTimeInterval(3600),
        key: DPoPKey = DPoPKey.P256()
    ) -> Session {
        Session(
            did: did,
            handle: handle,
            pdsURL: pdsURL,
            authorizationServer: serverMetadata(),
            login: login(accessToken: accessToken, refreshToken: refreshToken, expiry: expiry),
            dpopKey: key
        )
    }
}

extension StubHTTPClient {
    /// Handle → DID via the public API, and the DID document from PLC.
    func stubIdentity(did: String = Fixtures.did, handle: String = Fixtures.handle, pds: URL = Fixtures.pdsURL) {
        on("https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle", json: #"{"did": "\#(did)"}"#)
        on("https://plc.directory/\(did)", json: Fixtures.didDocument(did: did, handle: handle, pds: pds))
    }

    /// The PDS's protected-resource document and the auth server's metadata.
    func stubOAuthDiscovery(pds: URL = Fixtures.pdsURL, issuer: URL = Fixtures.issuer, metadataIssuer: URL? = nil) {
        on("\(pds.absoluteString)/.well-known/oauth-protected-resource", json: Fixtures.protectedResource(issuer: issuer))
        on(
            "\(issuer.absoluteString)/.well-known/oauth-authorization-server",
            json: Fixtures.authorizationServerMetadata(issuer: metadataIssuer ?? issuer)
        )
    }

    /// A pushed authorization request that succeeds straight away.
    func stubPAR(requestURI: String = "urn:ietf:params:oauth:request_uri:abc") {
        on(Fixtures.parEndpoint, status: 201, json: #"{"request_uri": "\#(requestURI)", "expires_in": 60}"#)
    }

    func requests(to prefix: String) -> [HTTPRequest] {
        requests.filter { $0.url.absoluteString.hasPrefix(prefix) }
    }
}

extension Data {
    /// Base64url without padding, as JOSE uses.
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func fromBase64URL(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}

/// A compact JWS pulled apart far enough to assert on, plus signature
/// verification so tests prove the proof is really signed by the key.
struct DecodedProof {
    let header: [String: Any]
    let payload: [String: Any]
    let signingInput: String
    let signature: Data

    init?(_ jwt: String?) {
        guard let jwt else { return nil }
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = Data.fromBase64URL(parts[0]),
              let payloadData = Data.fromBase64URL(parts[1]),
              let signature = Data.fromBase64URL(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            return nil
        }
        self.header = header
        self.payload = payload
        self.signingInput = parts[0] + "." + parts[1]
        self.signature = signature
    }

    var jwk: [String: Any]? { header["jwk"] as? [String: Any] }
    var nonce: String? { payload["nonce"] as? String }

    func isSigned(by publicKey: P256.Signing.PublicKey) -> Bool {
        guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return publicKey.isValidSignature(signature, for: Data(signingInput.utf8))
    }

    /// The public key the proof advertises in its header.
    func advertisedPublicKey() -> P256.Signing.PublicKey? {
        guard let jwk, let x = jwk["x"] as? String, let y = jwk["y"] as? String,
              let xData = Data.fromBase64URL(x), let yData = Data.fromBase64URL(y)
        else { return nil }
        return try? P256.Signing.PublicKey(rawRepresentation: xData + yData)
    }
}

/// The base64url SHA-256 of a string, as `ath` and PKCE challenges use.
func sha256URL(_ string: String) -> String {
    Data(SHA256.hash(data: Data(string.utf8))).base64URL
}

/// Decodes an `application/x-www-form-urlencoded` request body. Tolerates
/// the unencoded spaces OAuthenticator's PAR body uses.
func formFields(of request: HTTPRequest) -> [String: String] {
    guard let body = request.body, let string = String(data: body, encoding: .utf8) else { return [:] }
    var fields: [String: String] = [:]
    for pair in string.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { continue }
        fields[parts[0].removingPercentEncoding ?? parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
    }
    return fields
}

/// A JSON request body as a dictionary.
func jsonFields(of request: HTTPRequest) -> [String: Any] {
    guard let body = request.body else { return [:] }
    return (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
}

/// The query parameters of a URL, decoded.
func queryParameters(of url: URL) -> [String: String] {
    var result: [String: String] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
        result[item.name] = item.value ?? ""
    }
    return result
}

/// Runs `body`, which must throw, and returns what it threw (failing the
/// test if it didn't).
func errorThrown<T>(file: StaticString = #filePath, line: UInt = #line, by body: () async throws -> T) async -> Error? {
    do {
        _ = try await body()
        XCTFail("Expected an error to be thrown", file: file, line: line)
        return nil
    } catch {
        return error
    }
}
