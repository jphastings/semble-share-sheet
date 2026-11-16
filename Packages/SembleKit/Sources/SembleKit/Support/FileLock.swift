import Foundation

/// An exclusive advisory lock (`flock(2)`) on a file, held for the duration
/// of an async closure. Every open of the same path contends — across
/// processes sharing an app-group container, and between separate opens in
/// one process — so it serialises the app and the share extension as well
/// as two clients in the same process.
///
/// With no `url`, or if the file can't be opened or locked for any reason
/// other than another holder, `body` runs unlocked rather than not at all.
struct FileLock: Sendable {
    let url: URL?

    func withLock<T>(_ body: () async throws -> T) async throws -> T {
        guard let url else { return try await body() }
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return try await body() }
        // Closing the descriptor releases the lock, including when the
        // process dies while holding it.
        defer { close(descriptor) }
        // Polled rather than a blocking `flock`, so waiting never ties up a
        // cooperative-pool thread.
        // ponytail: no timeout; the holder's own request timeouts bound the wait.
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0, errno == EWOULDBLOCK || errno == EINTR {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return try await body()
    }
}
