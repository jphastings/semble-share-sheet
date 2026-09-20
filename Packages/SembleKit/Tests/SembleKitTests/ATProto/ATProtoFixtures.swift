import CryptoKit
import Foundation
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
    static let clientID = URL(string: "https://app.example/client-metadata.json")!
    static let redirectURI = URL(string: "io.github.jphastings:/oauth/callback")!
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

    static func authorizationServerMetadata(issuer: URL = issuer) -> String {
        """
        {
          "issuer": "\(issuer.absoluteString)",
          "authorization_endpoint": "\(authorizeEndpoint)",
          "token_endpoint": "\(tokenEndpoint)",
          "pushed_authorization_request_endpoint": "\(parEndpoint)",
          "dpop_signing_alg_values_supported": ["ES256"],
          "code_challenge_methods_supported": ["S256"]
        }
        """
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

    static func useDPoPNonce(_ nonce: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 400,
            headers: ["DPoP-Nonce": nonce, "Content-Type": "application/json"],
            body: Data(#"{"error": "use_dpop_nonce", "error_description": "Authorization server requires nonce in DPoP proof"}"#.utf8)
        )
    }

    static func session(
        accessToken: String = "access-0",
        refreshToken: String = "refresh-0",
        expiresAt: Date? = Date().addingTimeInterval(3600),
        privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()
    ) -> Session {
        Session(
            did: did,
            handle: handle,
            pdsURL: pdsURL,
            authorizationServer: issuer,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scope: scope,
            dpopPrivateKey: privateKey.rawRepresentation
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

    func requests(to prefix: String) -> [HTTPRequest] {
        requests.filter { $0.url.absoluteString.hasPrefix(prefix) }
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
              let headerData = Data(base64URLEncoded: parts[0]),
              let payloadData = Data(base64URLEncoded: parts[1]),
              let signature = Data(base64URLEncoded: parts[2]),
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
              let xData = Data(base64URLEncoded: x), let yData = Data(base64URLEncoded: y)
        else { return nil }
        return try? P256.Signing.PublicKey(rawRepresentation: xData + yData)
    }
}

/// Decodes an `application/x-www-form-urlencoded` request body.
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
