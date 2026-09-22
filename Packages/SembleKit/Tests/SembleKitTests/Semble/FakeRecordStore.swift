import Foundation
@testable import SembleKit

/// An in-memory `RecordStore`. Records every write as `(collection, rkey,
/// JSON)` in order and hands back deterministic strong refs
/// (`at://did:plc:test/<collection>/<rkey>`), so tests can assert on what was
/// written and in which order. A duplicate `rkey` in the same collection is
/// rejected the way a real PDS rejects it: an `XRPCError.server`.
/// `listRecords` serves canned pages keyed by cursor.
final class FakeRecordStore: RecordStore, @unchecked Sendable {
    struct Write {
        let collection: String
        let rkey: String
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
    /// Every record ever accepted, keyed by `"<collection>/<rkey>"`, for `getRecord`.
    private var recordsByKey: [String: (uri: String, cid: String, data: Data)] = [:]
    /// When set, `createRecord` throws this. Every call throws unless
    /// `createErrorAtCall` narrows it to one specific attempt.
    var createError: Error?
    /// 1-based `createRecord` call number (across the store's whole
    /// lifetime, not per save) that should throw `createError`. `nil` (the
    /// default) means every call throws.
    var createErrorAtCall: Int?
    private var createCallCount = 0

    init(did: String = "did:plc:test") {
        self.storedDID = did
    }

    var did: String {
        get async { storedDID }
    }

    func servePage(_ page: CannedPage, forCursor cursor: String? = nil) {
        lock.withLock { pages[cursor ?? ""] = page }
    }

    func createRecord<R: Encodable>(collection: String, record: R, rkey: String?) async throws -> StrongRef {
        let callNumber = lock.withLock { () -> Int in
            createCallCount += 1
            return createCallCount
        }
        if let createError, createErrorAtCall == nil || createErrorAtCall == callNumber {
            throw createError
        }
        let data = try JSONEncoder().encode(record)
        return try lock.withLock { () throws -> StrongRef in
            let resolvedRkey = rkey ?? "\(writes.count + 1)"
            let key = "\(collection)/\(resolvedRkey)"
            if let rkey, recordsByKey[key] != nil {
                throw XRPCError.server(status: 400, error: "InvalidSwap", message: "Record already exists at \(rkey)")
            }
            let uri = "at://did:plc:test/\(collection)/\(resolvedRkey)"
            let cid = "bafy\(writes.count + 1)"
            writes.append(Write(collection: collection, rkey: resolvedRkey, data: data))
            recordsByKey[key] = (uri: uri, cid: cid, data: data)
            return StrongRef(uri: uri, cid: cid)
        }
    }

    func getRecord<R: Decodable>(collection: String, rkey: String) async throws -> RecordEnvelope<R> {
        let stored = lock.withLock { recordsByKey["\(collection)/\(rkey)"] }
        guard let stored else {
            throw XRPCError.server(status: 404, error: "RecordNotFound", message: nil)
        }
        let value = try JSONDecoder().decode(R.self, from: stored.data)
        return RecordEnvelope(uri: stored.uri, cid: stored.cid, value: value)
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
