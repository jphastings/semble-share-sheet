import Foundation
import Jot
import OAuthenticator

/// Builds the DPoP proofs (RFC 9449) OAuthenticator attaches to every
/// request, signed with Jot.
///
/// A proof is a short-lived ES256 JWT that names the request it is for
/// (`htm`, `htu`), a unique id (`jti`), when it was made (`iat`), the
/// server's latest nonce when there is one, and the hash of the access token
/// it accompanies (`ath`). OAuthenticator works out those values; this type
/// only turns them into a signed token, embedding the public key as a JWK.
public enum DPoPProofs {
    /// The claims ATProto authorization servers and PDSs look for.
    struct Claims: JSONWebTokenPayload {
        let jti: String?
        let iat: Date?
        let htm: String?
        let htu: String?
        let nonce: String?
        let ath: String?
    }

    /// A generator bound to `key`, for `Bluesky.tokenHandling(jwtGenerator:)`.
    public static func generator(for key: DPoPKey) -> DPoPSigner.JWTGenerator {
        { parameters in
            let privateKey = try key.p256PrivateKey
            let token = JSONWebToken(
                header: JSONWebTokenHeader(
                    algorithm: .ES256,
                    type: parameters.keyType,
                    jwk: JSONWebKey(p256Key: privateKey.publicKey)
                ),
                payload: Claims(
                    jti: UUID().uuidString,
                    iat: Date(),
                    htm: parameters.httpMethod,
                    htu: parameters.requestEndpoint,
                    nonce: parameters.nonce,
                    ath: parameters.tokenHash
                )
            )
            return try token.encode(with: privateKey)
        }
    }
}
