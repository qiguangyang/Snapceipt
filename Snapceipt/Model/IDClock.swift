import Foundation

/// Client-generated identifiers. UUIDv7 (RFC 9562) is time-ordered + sortable,
/// so ids are offline-safe and stable across the sync round-trip.
enum ID {
    /// Generates an RFC 9562 UUIDv7 string (lowercase, hyphenated).
    static func uuidv7() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)

        // 48-bit big-endian Unix epoch milliseconds in bytes[0..5].
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        bytes[0] = UInt8((ms >> 40) & 0xFF)
        bytes[1] = UInt8((ms >> 32) & 0xFF)
        bytes[2] = UInt8((ms >> 24) & 0xFF)
        bytes[3] = UInt8((ms >> 16) & 0xFF)
        bytes[4] = UInt8((ms >> 8) & 0xFF)
        bytes[5] = UInt8(ms & 0xFF)

        // 10 random bytes for rand_a (bytes[6..7]) + rand_b (bytes[8..15]).
        var rand = [UInt8](repeating: 0, count: 10)
        for i in rand.indices { rand[i] = UInt8.random(in: 0...255) }

        // bytes[6]: version 7 (0111) in the high nibble + 4 random bits.
        bytes[6] = 0x70 | (rand[0] & 0x0F)
        bytes[7] = rand[1]
        // bytes[8]: variant 10xx + 6 random bits.
        bytes[8] = 0x80 | (rand[2] & 0x3F)
        bytes[9] = rand[3]
        bytes[10] = rand[4]
        bytes[11] = rand[5]
        bytes[12] = rand[6]
        bytes[13] = rand[7]
        bytes[14] = rand[8]
        bytes[15] = rand[9]

        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let s = Array(hex)
        return String(s[0..<8]) + "-"
            + String(s[8..<12]) + "-"
            + String(s[12..<16]) + "-"
            + String(s[16..<20]) + "-"
            + String(s[20..<32])
    }
}

/// Epoch-millisecond clock. All `createdAt`/`updatedAt`/`deletedAt` timestamps
/// (the LWW + cursor key) are integer ms in UTC.
enum Epoch {
    /// DEBUG-only pin for deterministic UI-test/tour runs. When non-nil, `nowMs()`
    /// and `now()` return this fixed instant instead of the wall clock. nil in
    /// Release (the property is compiled out).
    #if DEBUG
    static var override: Int?
    #endif

    /// Current time as integer epoch milliseconds (or the pinned override).
    static func nowMs() -> Int {
        #if DEBUG
        if let override { return override }
        #endif
        return Int((Date().timeIntervalSince1970 * 1000).rounded())
    }

    /// Current time as a `Date` (or the pinned override). Used by seeders.
    static func now() -> Date {
        Date(timeIntervalSince1970: Double(nowMs()) / 1000)
    }
}
