import Foundation

/// A `com.atproto.repo.strongRef`: a record's AT URI pinned to a specific
/// content hash, so a reference can never silently point at edited content.
public struct StrongRef: Codable, Hashable, Sendable {
    public let uri: String
    public let cid: String

    public init(uri: String, cid: String) {
        self.uri = uri
        self.cid = cid
    }

    public var atURI: ATURI? { ATURI(uri) }
}

/// A parsed `at://` URI of the form `at://<did>/<collection>/<rkey>`.
public struct ATURI: Hashable, Sendable, CustomStringConvertible {
    public let did: String
    public let collection: String
    public let rkey: String

    public init(did: String, collection: String, rkey: String) {
        self.did = did
        self.collection = collection
        self.rkey = rkey
    }

    public init?(_ string: String) {
        guard string.hasPrefix("at://") else { return nil }
        let parts = string.dropFirst("at://".count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        self.init(did: String(parts[0]), collection: String(parts[1]), rkey: String(parts[2]))
    }

    public var description: String { "at://\(did)/\(collection)/\(rkey)" }
}
