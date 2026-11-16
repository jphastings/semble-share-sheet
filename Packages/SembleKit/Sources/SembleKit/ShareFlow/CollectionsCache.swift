import Foundation

/// The last-known collection lists for each DID, kept in the app-group
/// container so the picker has something to show before (or instead of) a
/// network round trip. Two JSON files per DID — the user's own collections,
/// and the shared ones they've contributed to — each simply replaced on
/// every successful refresh, since it's a cache and never needs to merge.
public final class CollectionsCache: @unchecked Sendable {
    private let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// - Parameter shared: The shared list rather than the user's own.
    public func load(for did: String, shared: Bool = false) -> [CollectionSummary]? {
        guard let data = try? Data(contentsOf: url(for: did, shared: shared)) else { return nil }
        return try? JSONDecoder().decode([CollectionSummary].self, from: data)
    }

    /// - Parameter shared: The shared list rather than the user's own.
    public func save(_ collections: [CollectionSummary], for did: String, shared: Bool = false) {
        guard let data = try? JSONEncoder().encode(collections) else { return }
        try? data.write(to: url(for: did, shared: shared), options: .atomic)
    }

    private func url(for did: String, shared: Bool) -> URL {
        // Percent-encoding leaves only alphanumerics, so the "." suffix can't collide with a DID.
        let filename = (did.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? did) + (shared ? ".shared" : "")
        return directory.appendingPathComponent(filename).appendingPathExtension("json")
    }
}
