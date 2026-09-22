import Foundation

/// Pending saves, one JSON file per item, in the app-group container so the
/// app and the share extension share one queue. The share extension can die
/// the moment its sheet closes, so nothing here assumes a process survives
/// between `enqueue` and the write actually landing.
///
/// A file's extension is its state:
/// - `<id>.json` — queued, waiting for a drain.
/// - `<id>.inflight` — claimed by whichever process is currently trying it.
/// - `<id>.failed` — given up on; see `drain(for:using:)`.
///
/// Claiming is an atomic rename (`<id>.json` → `<id>.inflight`): `rename(2)`
/// guarantees that when two processes race to claim the same item, exactly
/// one of them wins, so the app draining on foreground, the share extension
/// draining on open, and the share extension's own save can never all write
/// the same item twice.
public final class SaveQueue: @unchecked Sendable {
    private let directory: URL
    /// How long an `.inflight` claim may sit before another drain assumes
    /// the process that made it died mid-write and reclaims it.
    private let abandonedClaimAge: TimeInterval
    private let fileManager = FileManager.default

    public convenience init(directory: URL) {
        self.init(directory: directory, abandonedClaimAge: 5 * 60)
    }

    /// For tests: a short `abandonedClaimAge` so reclaiming a stale claim
    /// doesn't need a real five-minute wait.
    init(directory: URL, abandonedClaimAge: TimeInterval) {
        self.directory = directory
        self.abandonedClaimAge = abandonedClaimAge
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Enqueuing

    /// Writes `pending` to disk, replacing any earlier version of the same
    /// item. Its rkeys never change between calls, so this is always safe.
    public func enqueue(_ pending: PendingSave) throws {
        try write(JSONEncoder().encode(pending), to: url(pending.id, "json"))
    }

    /// Removes every trace of `id` from the queue without attempting it.
    public func remove(_ id: UUID) {
        delete(id, "json")
        delete(id, "inflight")
        delete(id, "failed")
    }

    // MARK: Attempting

    public enum Attempt: Equatable {
        case saved
        /// Still queued, either because the write failed transiently or
        /// because another process already had it claimed.
        case queued
        case failed(String)
    }

    /// Claims `pending` — which must already be enqueued — and tries it once,
    /// right away. Unlike `drain(for:using:)`, a permanent failure here
    /// removes the item instead of parking it: the caller is showing the
    /// user the error as it happens, and retrying re-enqueues the very same
    /// `PendingSave` (same rkeys) rather than relying on a silent retry.
    @discardableResult
    public func attempt(_ pending: PendingSave, using library: any Library) async -> Attempt {
        guard claim(pending.id) else { return .queued }
        do {
            _ = try await library.save(pending)
            delete(pending.id, "inflight")
            return .saved
        } catch {
            if isPermanentFailure(error) {
                delete(pending.id, "inflight")
                return .failed(error.localizedDescription)
            }
            release(pending.id)
            return .queued
        }
    }

    /// Tries every item queued for `did`; items belonging to another DID are
    /// left completely untouched (not even claimed).
    public func drain(for did: String, using library: any Library) async {
        reclaimAbandonedClaims()
        for id in queuedIDs() {
            guard let peeked = try? peek(id), peeked.did == did else { continue }
            guard let pending = claimAndLoad(id) else { continue }
            do {
                _ = try await library.save(pending)
                delete(id, "inflight")
            } catch {
                if isPermanentFailure(error) {
                    // ponytail: parked items are invisible until there's an
                    // app-side pending/failed list (SEMBLE-16dh's own
                    // breakdown defers that UI); for now they just stop
                    // being retried.
                    try? rename(id, from: "inflight", to: "failed")
                } else {
                    release(id)
                }
            }
        }
    }

    // MARK: Claiming

    private func claim(_ id: UUID) -> Bool {
        guard (try? rename(id, from: "json", to: "inflight")) != nil else { return false }
        // A rename keeps the enqueue-time mtime; stamp the claim time so
        // `reclaimAbandonedClaims` doesn't mistake a live claim on an old
        // item for an abandoned one.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url(id, "inflight").path)
        return true
    }

    private func claimAndLoad(_ id: UUID) -> PendingSave? {
        guard claim(id) else { return nil }
        guard let pending = try? load(id, "inflight") else {
            // Claimed but unreadable (truncated write, corrupt JSON): park it
            // rather than leave an `.inflight` file no drain will ever
            // resolve.
            try? rename(id, from: "inflight", to: "failed")
            return nil
        }
        return pending
    }

    private func release(_ id: UUID) {
        try? rename(id, from: "inflight", to: "json")
    }

    /// `.inflight` files older than `abandonedClaimAge` belong to a process
    /// that died before it could resolve the claim; put them back in the
    /// queue for the next drain to try.
    private func reclaimAbandonedClaims() {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-abandonedClaimAge)
        for entry in entries where entry.pathExtension == "inflight" {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified < cutoff, let id = UUID(uuidString: entry.deletingPathExtension().lastPathComponent) else { continue }
            release(id)
        }
    }

    private func queuedIDs() -> [UUID] {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
    }

    // MARK: Disk I/O

    private func peek(_ id: UUID) throws -> PendingSave {
        try load(id, "json")
    }

    private func load(_ id: UUID, _ ext: String) throws -> PendingSave {
        try JSONDecoder().decode(PendingSave.self, from: Data(contentsOf: url(id, ext)))
    }

    private func url(_ id: UUID, _ ext: String) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(ext)
    }

    private func delete(_ id: UUID, _ ext: String) {
        try? fileManager.removeItem(at: url(id, ext))
    }

    private func rename(_ id: UUID, from: String, to: String) throws {
        try fileManager.moveItem(at: url(id, from), to: url(id, to))
    }

    /// Atomic write with file protection, so a pending save's URL and note
    /// stay encrypted at rest until the device has been unlocked once since boot.
    private func write(_ data: Data, to fileURL: URL) throws {
        try data.write(to: fileURL, options: .atomic)
        #if os(iOS)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: fileURL.path)
        #endif
    }
}
