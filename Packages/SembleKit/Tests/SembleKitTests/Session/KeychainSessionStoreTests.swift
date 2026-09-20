#if canImport(Security)
import Foundation
import Security
import XCTest
@testable import SembleKit

/// Runs the `SessionStore` contract against the real Keychain. A generic
/// password item with no access group needs no entitlements, so this works
/// for an unsigned `swift test` on macOS; if the Keychain itself is
/// unavailable (locked, or no login keychain on a headless runner) the test
/// is skipped rather than failed, since that says nothing about our code.
final class KeychainSessionStoreTests: XCTestCase {
    // XCTest makes a fresh instance per test method, so each test gets its
    // own item and can't see another's leftovers.
    private let store = KeychainSessionStore(service: "so.semble.share.tests.\(UUID().uuidString)", accessGroup: nil)

    override func setUpWithError() throws {
        try super.setUpWithError()
        try skipUnlessKeychainIsUsable()
    }

    override func tearDownWithError() throws {
        try? store.clear()
        try super.tearDownWithError()
    }

    private func skipUnlessKeychainIsUsable() throws {
        do {
            try store.save(SessionFixtures.session())
            try store.clear()
        } catch let error as KeychainError {
            throw XCTSkip("Keychain unavailable in this environment: \(error.localizedDescription)")
        }
    }

    func testEmptyStoreLoadsNil() throws {
        try SessionStoreContractTests.assertEmptyStoreLoadsNil(store)
    }

    func testSavedSessionLoadsBackEqual() throws {
        try SessionStoreContractTests.assertSavedSessionLoadsBackEqual(store)
    }

    func testSavingAgainReplacesTheSession() throws {
        try SessionStoreContractTests.assertSavingAgainReplaces(store)
    }

    func testClearForgetsTheSessionAndIsIdempotent() throws {
        try SessionStoreContractTests.assertClearForgets(store)
    }

    func testStoresAreIsolatedByService() throws {
        let other = KeychainSessionStore(service: "so.semble.share.tests.other.\(UUID().uuidString)", accessGroup: nil)
        defer { try? other.clear() }
        try store.save(SessionFixtures.session())
        XCTAssertNil(try other.load())
    }

    func testKeychainErrorDescribesTheStatus() {
        let error = KeychainError(status: errSecItemNotFound)
        XCTAssertEqual(error.status, errSecItemNotFound)
        XCTAssertFalse(error.localizedDescription.isEmpty)
        XCTAssertTrue(error.localizedDescription.contains("Keychain"))
    }
}
#endif
