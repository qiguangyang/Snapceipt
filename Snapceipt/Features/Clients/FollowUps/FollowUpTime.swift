import Foundation

enum FollowUpTime {
    struct Resolution {
        let instant: Date
        let isAmbiguous: Bool
        let offsetSeconds: Int
        var offsetDescription: String {
            let magnitude = abs(offsetSeconds)
            return String(format: "UTC%@%02d:%02d", offsetSeconds >= 0 ? "+" : "−", magnitude / 3600, magnitude % 3600 / 60)
        }
    }
    enum InvalidTime: LocalizedError {
        case timezone, missing
        var errorDescription: String? {
            switch self {
            case .timezone: "Choose a valid timezone."
            case .missing: "This clock time does not exist in the chosen timezone. Choose another time."
            }
        }
    }
    static func resolve(components: DateComponents, timezone: String) throws -> Resolution {
        guard let zone = TimeZone(identifier: timezone) else { throw InvalidTime.timezone }
        guard let y = components.year, let m = components.month, let d = components.day,
              let h = components.hour, let min = components.minute else { throw InvalidTime.missing }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var match = DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: components.second ?? 0)
        match.timeZone = zone
        // Search from before the requested civil day, with strict matching (no DST normalization).
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let anchor = utc.date(from: DateComponents(year: y, month: m, day: d))?.addingTimeInterval(-172800),
              let first = calendar.nextDate(after: anchor, matching: match, matchingPolicy: .strict, repeatedTimePolicy: .first),
              let last = calendar.nextDate(after: anchor, matching: match, matchingPolicy: .strict, repeatedTimePolicy: .last) else { throw InvalidTime.missing }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: first)
        guard actual.year == y && actual.month == m && actual.day == d && actual.hour == h && actual.minute == min else { throw InvalidTime.missing }
        return Resolution(instant: first, isAmbiguous: first != last, offsetSeconds: zone.secondsFromGMT(for: first))
    }
}
