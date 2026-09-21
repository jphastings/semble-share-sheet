import Foundation
import OAuthenticator
import XCTest
@testable import SembleKit

/// Fixtures shared by the session tests.
enum SessionFixtures {
    static func session(handle: String? = "alice.test") -> Session {
        Session(
            did: "did:plc:alice",
            handle: handle,
            pdsURL: URL(string: "https://pds.example")!,
            authorizationServer: Fixtures.serverMetadata(),
            login: Login(
                accessToken: Token(value: "access-token", expiry: Date(timeIntervalSince1970: 1_700_000_000)),
                refreshToken: Token(value: "refresh-token"),
                scopes: "atproto include:network.cosmik.authFull",
                issuingServer: "https://auth.example",
                additionalParams: ["did": "did:plc:alice"]
            ),
            dpopKey: DPoPKey(keyData: Data((0 ..< 32).map { UInt8($0) }))
        )
    }
}

/// The behaviour every `SessionStore` must have, exercised here against
/// `InMemorySessionStore`. `KeychainSessionStoreTests` runs the same checks
/// against the real Keychain where it can.
final class SessionStoreContractTests: XCTestCase {
    func testSessionRoundTripsThroughJSON() throws {
        let original = SessionFixtures.session()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.dpopKey, original.dpopKey)
        XCTAssertEqual(decoded.authorizationServer, original.authorizationServer)
    }

    func testSessionWithoutHandleOrExpiryRoundTrips() throws {
        var original = SessionFixtures.session(handle: nil)
        original.login.accessToken = Token(value: "access-token", expiry: nil)
        let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded.isExpired, "a session with no expiry is never treated as expired")
    }

    func testEmptyStoreLoadsNil() throws {
        try Self.assertEmptyStoreLoadsNil(InMemorySessionStore())
    }

    func testSavedSessionLoadsBackEqual() throws {
        try Self.assertSavedSessionLoadsBackEqual(InMemorySessionStore())
    }

    func testSavingAgainReplacesTheSession() throws {
        try Self.assertSavingAgainReplaces(InMemorySessionStore())
    }

    func testClearForgetsTheSessionAndIsIdempotent() throws {
        try Self.assertClearForgets(InMemorySessionStore())
    }

    // MARK: - Contract

    static func assertEmptyStoreLoadsNil(_ store: SessionStore, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNil(try store.load(), file: file, line: line)
    }

    static func assertSavedSessionLoadsBackEqual(_ store: SessionStore, file: StaticString = #filePath, line: UInt = #line) throws {
        let session = SessionFixtures.session()
        try store.save(session)
        XCTAssertEqual(try store.load(), session, file: file, line: line)
    }

    static func assertSavingAgainReplaces(_ store: SessionStore, file: StaticString = #filePath, line: UInt = #line) throws {
        try store.save(SessionFixtures.session())
        var rotated = SessionFixtures.session()
        rotated.login.accessToken = Token(value: "new-access-token")
        rotated.login.refreshToken = Token(value: "new-refresh-token")
        try store.save(rotated)
        XCTAssertEqual(try store.load(), rotated, file: file, line: line)
    }

    static func assertClearForgets(_ store: SessionStore, file: StaticString = #filePath, line: UInt = #line) throws {
        try store.save(SessionFixtures.session())
        try store.clear()
        XCTAssertNil(try store.load(), file: file, line: line)
        // Clearing an already-empty store is not an error: sign-out must
        // never fail because there was nothing to sign out of.
        XCTAssertNoThrow(try store.clear(), file: file, line: line)
    }
}
