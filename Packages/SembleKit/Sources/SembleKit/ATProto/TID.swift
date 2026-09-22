import Foundation

/// Generates ATProto Timestamp Identifiers: the client-chosen record keys
/// that make a write idempotent. See https://atproto.com/specs/tid.
///
/// A TID is a 64-bit integer — top bit `0`, then 53 bits of microseconds
/// since the Unix epoch, then 10 bits of random "clock identifier" — encoded
/// as 13 characters of base32-sortable text, so TIDs minted in order also
/// sort in order.
public enum TID {
    private static let alphabet = Array("234567abcdefghijklmnopqrstuvwxyz")
    private static let clock = MonotonicMicroseconds()

    /// A new TID, unique and strictly greater than every other one minted by
    /// this process, even when called repeatedly within the same microsecond.
    public static func next(now: Date = Date()) -> String {
        let requested = UInt64(max(now.timeIntervalSince1970, 0) * 1_000_000)
        let micros = clock.next(atLeast: requested)
        let clockID = UInt64.random(in: 0 ..< 1024)
        // 53 bits of micros, then 10 bits of clock id; the remaining top bit
        // of the 64-bit value is left 0, as the spec requires.
        let value = ((micros & 0x1F_FFFF_FFFF_FFFF) << 10) | clockID
        return encode(value)
    }

    private static func encode(_ value: UInt64) -> String {
        var characters = [Character](repeating: alphabet[0], count: 13)
        var remaining = value
        for index in stride(from: 12, through: 0, by: -1) {
            characters[index] = alphabet[Int(remaining & 0x1F)]
            remaining >>= 5
        }
        return String(characters)
    }
}

/// Hands out ever-increasing microsecond values, process-wide. `SembleLibrary`
/// mints a card, note and link rkey for one save in a tight loop, easily
/// within the same microsecond; without this they could collide (the card
/// and note share a collection, so on a collision the note's create would be
/// rejected and the card adopted in its place).
private final class MonotonicMicroseconds: @unchecked Sendable {
    private let lock = NSLock()
    private var last: UInt64 = 0

    func next(atLeast requested: UInt64) -> UInt64 {
        lock.withLock {
            last = Swift.max(requested, last + 1)
            return last
        }
    }
}
