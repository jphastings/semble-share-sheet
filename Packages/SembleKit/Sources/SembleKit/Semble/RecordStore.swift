import Foundation

/// The slice of `PDSClient` that `SembleLibrary` uses. `PDSClient` is an
/// actor that needs a live OAuth session, so the library talks to this
/// protocol instead and tests substitute an in-memory store.
protocol RecordStore: Sendable {
    /// The DID of the repository being written to (the signed-in user).
    var did: String { get async }
    func createRecord<R: Encodable>(collection: String, record: R) async throws -> StrongRef
    func listRecords<R: Decodable>(collection: String, limit: Int, cursor: String?) async throws -> RecordPage<R>
}

extension PDSClient: RecordStore {}
