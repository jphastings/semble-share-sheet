import Foundation

/// Formats dates the way AT Protocol lexicons expect (`format: "datetime"`):
/// RFC-3339 in UTC with millisecond precision and a literal `Z`, e.g.
/// `2026-09-20T12:34:56.789Z`. That is exactly what JavaScript's
/// `Date.toISOString()` produces, so records written here are byte-for-byte
/// the shape Semble's own backend writes.
///
/// `JSONEncoder`'s default date strategy is a floating-point number, which the
/// lexicon validator rejects, so record types encode their dates through this
/// explicitly rather than relying on whichever encoder the PDS client uses.
enum ATProtoDateFormatter {
    static func string(from date: Date) -> String {
        makeFormatter(fractionalSeconds: true).string(from: date)
    }

    /// Parses RFC-3339 with or without fractional seconds. Other repositories
    /// on the network may well have written the plain form.
    static func date(from string: String) -> Date? {
        if let date = makeFormatter(fractionalSeconds: true).date(from: string) {
            return date
        }
        return makeFormatter(fractionalSeconds: false).date(from: string)
    }

    // A fresh formatter per call: `ISO8601DateFormatter` is a reference type
    // and these calls are rare, so sharing one across concurrency domains
    // isn't worth the `Sendable` gymnastics.
    private static func makeFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if fractionalSeconds {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        } else {
            formatter.formatOptions = [.withInternetDateTime]
        }
        return formatter
    }
}

extension KeyedEncodingContainer {
    mutating func encodeATProtoDate(_ date: Date, forKey key: Key) throws {
        try encode(ATProtoDateFormatter.string(from: date), forKey: key)
    }

    mutating func encodeATProtoDateIfPresent(_ date: Date?, forKey key: Key) throws {
        guard let date else { return }
        try encodeATProtoDate(date, forKey: key)
    }
}

extension KeyedDecodingContainer {
    func decodeATProtoDate(forKey key: Key) throws -> Date {
        let raw = try decode(String.self, forKey: key)
        guard let date = ATProtoDateFormatter.date(from: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "\"\(raw)\" is not an RFC-3339 datetime"
            )
        }
        return date
    }

    func decodeATProtoDateIfPresent(forKey key: Key) throws -> Date? {
        guard let raw = try decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let date = ATProtoDateFormatter.date(from: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "\"\(raw)\" is not an RFC-3339 datetime"
            )
        }
        return date
    }
}
