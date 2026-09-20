import Foundation
@testable import SembleKit

/// An in-memory `RecordStore`. Records every write as `(collection, JSON)`
/// in order and hands back deterministic strong refs
/// (`at://did:plc:test/<collection>/<n>`), so tests can assert on what was
/// written and in which order. `listRecords` serves canned pages keyed by
/// cursor.
final class FakeRecordStore: RecordStore, @unchecked Sendable {
    struct Write {
        let collection: String
        let data: Data

        /// The written record as a JSON object, for assertions on keys.
        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
    }

    struct CannedRecord {
        let uri: String
        let cid: String
        let json: String
    }

    struct CannedPage {
        var records: [CannedRecord]
        var cursor: String?
    }

    struct ListCall: Equatable {
        let collection: String
        let limit: Int
        let cursor: String?
    }

    enum Failure: Error, Equatable {
        case noCannedPage(cursor: String?)
        case injected
    }

    private let lock = NSLock()
    private let storedDID: String
    private(set) var writes: [Write] = []
    private(set) var listCalls: [ListCall] = []
    /// Pages keyed by the cursor that requests them; the first page's key is `""`.
    private var pages: [String: CannedPage] = [:]
    /// When set, every `createRecord` throws this instead of writing.
    var createError: Error?

    init(did: String = "did:plc:test") {
        self.storedDID = did
    }

    var did: String {
        get async { storedDID }
    }

    func servePage(_ page: CannedPage, forCursor cursor: String? = nil) {
        lock.withLock { pages[cursor ?? ""] = page }
    }

    func createRecord<R: Encodable>(collection: String, record: R) async throws -> StrongRef {
        if let createError { throw createError }
        let data = try JSONEncoder().encode(record)
        return lock.withLock { () -> StrongRef in
            writes.append(Write(collection: collection, data: data))
            let n = writes.count
            return StrongRef(uri: "at://did:plc:test/\(collection)/\(n)", cid: "bafy\(n)")
        }
    }

    func listRecords<R: Decodable>(collection: String, limit: Int, cursor: String?) async throws -> RecordPage<R> {
        let page: CannedPage? = lock.withLock { () -> CannedPage? in
            listCalls.append(ListCall(collection: collection, limit: limit, cursor: cursor))
            return pages[cursor ?? ""]
        }
        guard let page else { throw Failure.noCannedPage(cursor: cursor) }
        let decoder = JSONDecoder()
        var envelopes: [RecordEnvelope<R>] = []
        for canned in page.records {
            let value = try decoder.decode(R.self, from: Data(canned.json.utf8))
            envelopes.append(RecordEnvelope(uri: canned.uri, cid: canned.cid, value: value))
        }
        return RecordPage(records: envelopes, cursor: page.cursor)
    }

    /// Writes to `collection`, in order.
    func writtenRecords(in collection: String) -> [Write] {
        lock.withLock { writes.filter { $0.collection == collection } }
    }
}
