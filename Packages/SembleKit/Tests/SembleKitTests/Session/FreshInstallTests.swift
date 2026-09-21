import Foundation
import XCTest
@testable import SembleKit

/// `clearSessionOnFreshInstall` uses a flag in `UserDefaults` to tell a
/// reinstall (Keychain survives, UserDefaults doesn't) from an ordinary
/// relaunch (both survive).
final class FreshInstallTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "so.semble.share.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFirstLaunchClearsAnyExistingSessionAndSetsTheFlag() throws {
        let store = InMemorySessionStore(session: SessionFixtures.session())

        clearSessionOnFreshInstall(store: store, defaults: defaults)

        XCTAssertNil(try store.load())
        XCTAssertTrue(defaults.bool(forKey: "hasLaunchedBefore"))
    }

    func testAFailedClearIsRetriedOnTheNextLaunch() throws {
        let store = FailingClearSessionStore()

        XCTAssertFalse(clearSessionOnFreshInstall(store: store, defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: "hasLaunchedBefore"))

        store.shouldFail = false
        XCTAssertTrue(clearSessionOnFreshInstall(store: store, defaults: defaults))
        XCTAssertNil(try store.load())
    }

    func testLaterLaunchesLeaveTheSessionAlone() throws {
        let store = InMemorySessionStore(session: SessionFixtures.session())
        defaults.set(true, forKey: "hasLaunchedBefore")

        clearSessionOnFreshInstall(store: store, defaults: defaults)

        XCTAssertNotNil(try store.load())
    }
}

private final class FailingClearSessionStore: SessionStore, @unchecked Sendable {
    var shouldFail = true
    private var session: Session? = SessionFixtures.session()

    func load() throws -> Session? { session }
    func save(_ session: Session) throws { self.session = session }

    func clear() throws {
        if shouldFail { throw KeychainError(status: errSecInteractionNotAllowed) }
        session = nil
    }
}
