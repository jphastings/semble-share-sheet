import CryptoKit
import Foundation

/// A P-256 public key in JSON Web Key form, as embedded in every DPoP proof
/// so the server can check the signature and bind tokens to the key.
public struct JWK: Codable, Equatable, Sendable {
    public let kty: String
    public let crv: String
    public let x: String
    public let y: String

    public init(kty: String = "EC", crv: String = "P-256", x: String, y: String) {
        self.kty = kty
        self.crv = crv
        self.x = x
        self.y = y
    }

    /// The `x` and `y` coordinates are the two 32-byte halves of the key's raw
    /// (uncompressed, unprefixed) representation.
    public init(publicKey: P256.Signing.PublicKey) {
        let raw = publicKey.rawRepresentation
        let half = raw.count / 2
        self.init(
            x: raw.prefix(half).base64URLEncodedString(),
            y: raw.suffix(from: raw.startIndex + half).base64URLEncodedString()
        )
    }
}

/// Signs DPoP proofs (RFC 9449), the mechanism ATProto uses to bind OAuth
/// tokens to a key the client holds.
///
/// Every request to the authorization server or the PDS carries a `DPoP`
/// header: a short-lived JWT, signed with our P-256 key, that names the HTTP
/// method and URL it is for (`htm`, `htu`), a unique id (`jti`), the time it
/// was made (`iat`), the server's most recent nonce when we know one, and —
/// when an access token accompanies the request — the token's SHA-256 hash
/// (`ath`). A stolen access token is therefore useless without the private
/// key, which never leaves the device.
///
/// The signer holds the key as its raw representation rather than as a
/// `P256.Signing.PrivateKey` so it is plainly `Sendable`; reconstructing the
/// key per proof is a few microseconds.
public struct DPoPProofSigner: Sendable {
    private let privateKeyData: Data

    /// The public half, ready to embed in a proof header.
    public let jwk: JWK

    public init(privateKey: P256.Signing.PrivateKey) {
        self.privateKeyData = privateKey.rawRepresentation
        self.jwk = JWK(publicKey: privateKey.publicKey)
    }

    /// Rebuilds a signer from `P256.Signing.PrivateKey.rawRepresentation`
    /// (which is how `Session.dpopPrivateKey` is stored).
    public init(rawRepresentation: Data) throws {
        let key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
        self.init(privateKey: key)
    }

    /// A signer with a brand-new key, for the start of an authorization.
    public static func generate() -> DPoPProofSigner {
        DPoPProofSigner(privateKey: P256.Signing.PrivateKey())
    }

    /// The private key's raw representation, for persisting in a `Session`.
    public var privateKeyRawRepresentation: Data { privateKeyData }

    public func publicKey() throws -> P256.Signing.PublicKey {
        try P256.Signing.PrivateKey(rawRepresentation: privateKeyData).publicKey
    }

    /// The RFC 7638 thumbprint of the public key: `base64url(SHA256(JWK))`
    /// with the JWK serialised as `{"crv","kty","x","y"}` in that order and
    /// with no whitespace, which is exactly what `JOSE.compactJSON` emits.
    public func thumbprint() throws -> String {
        let json = try JOSE.compactJSON(jwk)
        return Data(SHA256.hash(data: json)).base64URLEncodedString()
    }

    /// Builds a proof for one request.
    ///
    /// - Parameters:
    ///   - method: The HTTP method, e.g. `"POST"`. Upper-cased for `htm`.
    ///   - url: The request URL; the query and fragment are dropped for `htu`,
    ///     as the spec requires.
    ///   - nonce: The server's latest `DPoP-Nonce`, if we have one.
    ///   - accessToken: The access token the request carries, if any. Its
    ///     hash goes in `ath` so the proof can't be replayed with another
    ///     token. Requests to the authorization server itself have none.
    ///   - now: The proof's `iat`. Injectable for tests.
    ///   - jti: The unique proof id. Injectable for tests.
    public func proof(
        method: String,
        url: URL,
        nonce: String? = nil,
        accessToken: String? = nil,
        now: Date = Date(),
        jti: String = UUID().uuidString
    ) throws -> String {
        let header = Header(jwk: jwk)
        let payload = Payload(
            jti: jti,
            htm: method.uppercased(),
            htu: DPoPProofSigner.htu(for: url),
            iat: Int(now.timeIntervalSince1970),
            nonce: nonce,
            ath: accessToken.map { Data(SHA256.hash(data: Data($0.utf8))).base64URLEncodedString() }
        )
        let signingInput = try JOSE.segment(header) + "." + JOSE.segment(payload)
        let key = try P256.Signing.PrivateKey(rawRepresentation: privateKeyData)
        // ES256 is the raw 64-byte `r || s`, not the DER encoding.
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + signature.rawRepresentation.base64URLEncodedString()
    }

    /// The `htu` claim: the request URL without its query or fragment.
    static func htu(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? url.absoluteString
    }

    private struct Header: Encodable {
        var typ = "dpop+jwt"
        var alg = "ES256"
        var jwk: JWK
    }

    private struct Payload: Encodable {
        var jti: String
        var htm: String
        var htu: String
        var iat: Int
        // Optionals are omitted from the JSON when nil.
        var nonce: String?
        var ath: String?
    }
}
