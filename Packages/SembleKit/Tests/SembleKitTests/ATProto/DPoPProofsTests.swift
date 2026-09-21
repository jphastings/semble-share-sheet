import CryptoKit
import Foundation
import OAuthenticator
import XCTest
@testable import SembleKit

/// The proof generator only has to produce what OAuthenticator asks for, but
/// it must do so exactly: a wrong claim or a bad signature is a silent
/// sign-in failure on a real server.
final class DPoPProofsTests: XCTestCase {
    private let key = DPoPKey.P256()

    /// OAuthenticator's parameter type has no public initialiser, so proofs
    /// are produced the way the library itself does it: by signing a request.
    private actor Isolation {}

    private func proof(nonce: String? = nil, token: String? = nil, tokenHash: String? = nil) async throws -> String {
        var request = URLRequest(url: URL(string: "https://pds.example/xrpc/com.atproto.repo.createRecord?x=1")!)
        request.httpMethod = "POST"
        let signed = try await DPoPSigner().buildProof(
            request,
            isolation: Isolation(),
            using: DPoPProofs.generator(for: key),
            nonce: nonce,
            token: token,
            tokenHash: tokenHash
        )
        return try XCTUnwrap(signed.value(forHTTPHeaderField: "DPoP"))
    }

    func test_proofIsADPoPJWTSignedByTheKey() async throws {
        let jwt = try await proof()

        let proof = try XCTUnwrap(DecodedProof(jwt))
        XCTAssertEqual(proof.header["typ"] as? String, "dpop+jwt")
        XCTAssertEqual(proof.header["alg"] as? String, "ES256")
        XCTAssertEqual(proof.jwk?["kty"] as? String, "EC")
        XCTAssertEqual(proof.jwk?["crv"] as? String, "P-256")

        let publicKey = try key.p256PrivateKey.publicKey
        XCTAssertTrue(proof.isSigned(by: publicKey))
        XCTAssertEqual(proof.advertisedPublicKey()?.rawRepresentation, publicKey.rawRepresentation)
    }

    func test_proofNamesTheRequestAndTheMoment() async throws {
        let before = Int(Date().timeIntervalSince1970)
        let jwt = try await proof()
        let proof = try XCTUnwrap(DecodedProof(jwt))

        XCTAssertEqual(proof.payload["htm"] as? String, "POST")
        XCTAssertEqual(proof.payload["htu"] as? String, "https://pds.example/xrpc/com.atproto.repo.createRecord")
        XCTAssertFalse((proof.payload["jti"] as? String ?? "").isEmpty)
        let iat = try XCTUnwrap(proof.payload["iat"] as? Int)
        XCTAssertGreaterThanOrEqual(iat, before)
        XCTAssertNil(proof.payload["nonce"])
        XCTAssertNil(proof.payload["ath"])
    }

    func test_proofCarriesTheNonceAndTokenHashWhenGiven() async throws {
        let jwt = try await proof(nonce: "server-nonce", token: "access", tokenHash: "hash")
        let proof = try XCTUnwrap(DecodedProof(jwt))

        XCTAssertEqual(proof.nonce, "server-nonce")
        XCTAssertEqual(proof.payload["ath"] as? String, "hash")
    }

    func test_eachProofHasAFreshJTI() async throws {
        let first = DecodedProof(try await proof())?.payload["jti"] as? String
        let second = DecodedProof(try await proof())?.payload["jti"] as? String
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second)
    }
}
