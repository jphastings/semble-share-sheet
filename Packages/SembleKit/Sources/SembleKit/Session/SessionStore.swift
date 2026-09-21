import Foundation

/// Persists the signed-in `Session`. The production implementation is the
/// Keychain (shared with the share extension via an access group).
public protocol SessionStore: Sendable {
    func load() throws -> Session?
    func save(_ session: Session) throws
    func clear() throws
}

/// A session store that forgets everything when the process exits. Used by
/// tests and SwiftUI previews.
public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: Session?

    public init(session: Session? = nil) {
        self.session = session
    }

    public func load() throws -> Session? {
        lock.withLock { session }
    }

    public func save(_ session: Session) throws {
        lock.withLock { self.session = session }
    }

    public func clear() throws {
        lock.withLock { session = nil }
    }
}

/// Clears `store` the first time it's called for a given `defaults` suite,
/// then remembers it was called.
///
/// The Keychain outlives an uninstall; `UserDefaults` in the app group does
/// not. So a missing flag means either a true first launch or a reinstall
/// after an uninstall — either way, any session already in the Keychain is
/// stale (or, on a first launch, simply not ours to keep) and is cleared
/// before anything reads it.
/// The flag is set only once the clear has actually succeeded, so a Keychain
/// that was unreadable at launch is tried again next time rather than leaving
/// an inherited session in place for good.
@discardableResult
public func clearSessionOnFreshInstall(
    store: SessionStore,
    defaults: UserDefaults,
    launchedBeforeKey: String = "hasLaunchedBefore"
) -> Bool {
    guard !defaults.bool(forKey: launchedBeforeKey) else { return true }
    do {
        try store.clear()
    } catch {
        return false
    }
    defaults.set(true, forKey: launchedBeforeKey)
    return true
}
