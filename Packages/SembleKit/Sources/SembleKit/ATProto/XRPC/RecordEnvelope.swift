import Foundation

/// A record as the PDS returns it: its content plus the AT URI and CID that
/// identify it. `ref` is what other records point at.
public struct RecordEnvelope<Record: Decodable>: Decodable {
    public let uri: String
    public let cid: String
    public let value: Record

    public init(uri: String, cid: String, value: Record) {
        self.uri = uri
        self.cid = cid
        self.value = value
    }

    public var ref: StrongRef { StrongRef(uri: uri, cid: cid) }
}

extension RecordEnvelope: Equatable where Record: Equatable {}
extension RecordEnvelope: Sendable where Record: Sendable {}

/// One page of `com.atproto.repo.listRecords`. Pass `cursor` back to get the
/// next page; `nil` means this was the last one.
public struct RecordPage<Record: Decodable>: Decodable {
    public let records: [RecordEnvelope<Record>]
    public let cursor: String?

    public init(records: [RecordEnvelope<Record>], cursor: String?) {
        self.records = records
        self.cursor = cursor
    }
}

extension RecordPage: Equatable where Record: Equatable {}
extension RecordPage: Sendable where Record: Sendable {}
