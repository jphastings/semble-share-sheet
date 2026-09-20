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
