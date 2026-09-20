import CryptoKit
import XCTest
@testable import SembleKit

final class DPoPProofSignerTests: XCTestCase {
    private let url = URL(string: "https://pds.example/xrpc/com.atproto.repo.createRecord?ignored=1#frag")!

    func test_proofIsACompactJWSSignedByTheKey() throws {
        let key = P256.Signing.PrivateKey()
        let signer = DPoPProofSigner(privateKey: key)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let jwt = try signer.proof(method: "post", url: url, nonce: "server-nonce", accessToken: "token-123", now: now, jti: "proof-1")
        let proof = try XCTUnwrap(DecodedProof(jwt), "a proof is header.payload.signature, all base64url")

        XCTAssertEqual(proof.header["typ"] as? String, "dpop+jwt")
        XCTAssertEqual(proof.header["alg"] as? String, "ES256")
        XCTAssertEqual(proof.jwk?["kty"] as? String, "EC")
        XCTAssertEqual(proof.jwk?["crv"] as? String, "P-256")
        XCTAssertEqual(proof.advertisedPublicKey()?.rawRepresentation, key.publicKey.rawRepresentation)

        XCTAssertEqual(proof.payload["htm"] as? String, "POST")
        XCTAssertEqual(proof.payload["htu"] as? String, "https://pds.example/xrpc/com.atproto.repo.createRecord", "no query or fragment")
        XCTAssertEqual(proof.payload["jti"] as? String, "proof-1")
        XCTAssertEqual(proof.payload["iat"] as? Int, 1_700_000_000)
        XCTAssertEqual(proof.nonce, "server-nonce")
        let expectedAth = Data(SHA256.hash(data: Data("token-123".utf8))).base64URLEncodedString()
        XCTAssertEqual(proof.payload["ath"] as? String, expectedAth)

        XCTAssertTrue(proof.isSigned(by: key.publicKey))
        XCTAssertFalse(proof.isSigned(by: P256.Signing.PrivateKey().publicKey))
    }

    func test_proofOmitsNonceAndAthWhenThereAreNone() throws {
        let signer = DPoPProofSigner.generate()

        let jwt = try signer.proof(method: "POST", url: url)
        let proof = try XCTUnwrap(DecodedProof(jwt))

        XCTAssertNil(proof.payload["nonce"])
        XCTAssertNil(proof.payload["ath"])
        XCTAssertNotNil(proof.payload["jti"] as? String)
    }

    func test_eachProofHasAFreshJTI() throws {
        let signer = DPoPProofSigner.generate()

        let firstJWT = try signer.proof(method: "GET", url: url)
        let secondJWT = try signer.proof(method: "GET", url: url)
        let first = try XCTUnwrap(DecodedProof(firstJWT))
        let second = try XCTUnwrap(DecodedProof(secondJWT))

        XCTAssertNotEqual(first.payload["jti"] as? String, second.payload["jti"] as? String)
    }

    func test_signerRoundTripsThroughTheRawRepresentation() throws {
        let original = DPoPProofSigner.generate()

        let restored = try DPoPProofSigner(rawRepresentation: original.privateKeyRawRepresentation)

        XCTAssertEqual(restored.jwk, original.jwk)
        XCTAssertEqual(try restored.thumbprint(), try original.thumbprint())
        let jwt = try restored.proof(method: "GET", url: url)
        let proof = try XCTUnwrap(DecodedProof(jwt))
        let originalPublicKey = try original.publicKey()
        XCTAssertTrue(proof.isSigned(by: originalPublicKey))
    }

    func test_thumbprintIsSHA256OfTheCanonicalJWK() throws {
        let signer = DPoPProofSigner.generate()
        let canonical = #"{"crv":"P-256","kty":"EC","x":"\#(signer.jwk.x)","y":"\#(signer.jwk.y)"}"#

        let expected = Data(SHA256.hash(data: Data(canonical.utf8))).base64URLEncodedString()
        XCTAssertEqual(try signer.thumbprint(), expected)
    }

    func test_base64URLRoundTrips() {
        let bytes = Data([0xfb, 0xff, 0xfe, 0x00, 0x01])
        let encoded = bytes.base64URLEncodedString()

        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(Data(base64URLEncoded: encoded), bytes)
    }

    func test_pkceChallengeIsSHA256OfTheVerifier() {
        let pkce = PKCE()

        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)
        XCTAssertEqual(pkce.challenge, Data(SHA256.hash(data: Data(pkce.verifier.utf8))).base64URLEncodedString())
        XCTAssertNotEqual(PKCE().verifier, pkce.verifier)
    }
}
