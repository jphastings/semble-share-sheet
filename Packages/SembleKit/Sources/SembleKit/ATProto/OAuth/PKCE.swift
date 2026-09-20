import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636), `S256` flavour.
///
/// A public client has no secret, so PKCE is what stops someone who
/// intercepts the authorization code (say, by registering the same custom
/// URL scheme) from redeeming it: the token request must present the
/// `code_verifier` whose SHA-256 was sent, as `code_challenge`, when the
/// authorization was started. Only we ever held the verifier.
struct PKCE: Equatable, Sendable {
    static let method = "S256"

    let verifier: String
    let challenge: String

    /// A fresh verifier: 32 random bytes as base64url, which gives the 43
    /// unreserved characters RFC 7636 asks for as a minimum.
    init() {
        self.init(verifier: SecureRandom.token(bytes: 32))
    }

    init(verifier: String) {
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
    }

    /// `base64url(SHA256(ASCII(verifier)))`.
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}
