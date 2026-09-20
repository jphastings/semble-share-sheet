import Foundation

/// Base64url (RFC 4648 §5) without padding: the alphabet JOSE, PKCE and DPoP
/// all use. Foundation only speaks classic base64, so the translation lives
/// here.
extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: base64)
    }
}

/// Just enough JOSE to build a compact JWS: JSON segments, base64url encoded,
/// joined with dots. There is no general JWT parsing here on purpose; we only
/// ever *produce* tokens (DPoP proofs) and never need to trust one we
/// received.
enum JOSE {
    /// Encodes `value` as compact JSON and then base64url. Keys are sorted so
    /// the output is deterministic; that also makes the RFC 7638 JWK
    /// thumbprint (which requires lexicographic member order) fall out for
    /// free.
    static func segment<T: Encodable>(_ value: T) throws -> String {
        try compactJSON(value).base64URLEncodedString()
    }

    static func compactJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// Cryptographically secure random bytes for `state`, PKCE verifiers and
/// the like. `UInt8.random` uses the system generator, which is seeded from
/// the kernel on Apple platforms.
enum SecureRandom {
    static func data(count: Int) -> Data {
        Data((0 ..< count).map { _ in UInt8.random(in: UInt8.min ... UInt8.max) })
    }

    /// `count` random bytes as a base64url string, the shape OAuth wants for
    /// opaque, URL-safe values.
    static func token(bytes count: Int = 32) -> String {
        data(count: count).base64URLEncodedString()
    }
}
