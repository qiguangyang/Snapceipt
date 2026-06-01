import Foundation

/// Pure WFH (fixed-rate method) claim math. No SwiftData — callers pass plain
/// `Entry` snapshots so this stays unit-testable. (§5.2)
enum WFHCalc {
    /// A minimal WFH log snapshot for aggregation.
    struct Entry: Equatable {
        let logDate: String   // "yyyy-MM-dd"
        let minutes: Int
        let claimCents: Int
    }

    /// FY hero stats.
    struct Hero: Equatable {
        let totalMinutes: Int
        let claimCents: Int
        let daysLogged: Int
        let avgHoursPerDay: Double
    }

    private static let isoParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2   // Monday
        return c
    }

    /// Per-entry claim = round(minutes/60 * rate). Snapshotted at create/edit.
    static func claimCents(minutes: Int, rateCentsPerHour: Int) -> Int {
        Int((Double(minutes) / 60.0 * Double(rateCentsPerHour)).rounded())
    }

    /// FY aggregation over the entries in FY `fyStartYear`.
    static func hero(entries: [Entry], fyStartYear: Int, startMonth: Int) -> Hero {
        let inFY = entries.filter {
            FinancialYear.isIn($0.logDate, fyStartYear: fyStartYear, startMonth: startMonth)
        }
        let totalMinutes = inFY.reduce(0) { $0 + $1.minutes }
        let claim = inFY.reduce(0) { $0 + $1.claimCents }
        let days = inFY.count
        let avg = days == 0 ? 0 : (Double(totalMinutes) / 60.0) / Double(days)
        return Hero(totalMinutes: totalMinutes, claimCents: claim, daysLogged: days, avgHoursPerDay: avg)
    }

    /// Minutes per weekday (index 0 = Monday … 6 = Sunday) for the Mon–Sun week
    /// containing `today`.
    static func thisWeekMinutes(entries: [Entry], today: Date) -> [Int] {
        let cal = utcCalendar
        let interval = cal.dateInterval(of: .weekOfYear, for: today)!
        let monday = interval.start
        let nextMonday = interval.end
        var buckets = [Int](repeating: 0, count: 7)
        for e in entries {
            guard let date = isoParser.date(from: e.logDate),
                  date >= monday, date < nextMonday else { continue }
            let days = cal.dateComponents([.day], from: monday, to: date).day ?? 0
            if days >= 0 && days < 7 { buckets[days] += e.minutes }
        }
        return buckets
    }
}
