import Foundation

/// The last-known collection list for each DID, kept in the app-group
/// container so the picker has something to show before (or instead of) a
/// network round trip. One JSON file per DID; simply replaced on every
/// successful refresh, since it's a cache and never needs to merge.
public final class CollectionsCache: @unchecked Sendable {
    private let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func load(for did: String) -> [CollectionSummary]? {
        guard let data = try? Data(contentsOf: url(for: did)) else { return nil }
        return try? JSONDecoder().decode([CollectionSummary].self, from: data)
    }

    public func save(_ collections: [CollectionSummary], for did: String) {
        guard let data = try? JSONEncoder().encode(collections) else { return }
        try? data.write(to: url(for: did), options: .atomic)
    }

    private func url(for did: String) -> URL {
        let filename = did.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? did
        return directory.appendingPathComponent(filename).appendingPathExtension("json")
    }
}
