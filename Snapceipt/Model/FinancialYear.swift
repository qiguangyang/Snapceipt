import Foundation

/// AU financial-year boundaries/labels/membership, driven by
/// `tax_settings.financial_year_start_month` (7 => 1 Jul..30 Jun). All dates are
/// treated in UTC to match the app's "yyyy-MM-dd" ISO handling (Formatters.swift).
enum FinancialYear {
    /// One financial year's window + identity.
    struct Window: Equatable {
        let start: Date       // inclusive, 00:00 UTC on the 1st of `startMonth`
        let end: Date         // exclusive, 00:00 UTC on the 1st of `startMonth` a year later
        let startYear: Int    // 2025 => FY2025-26
        let label: String     // "FY2025-26"
    }

    private static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private static let isoParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "FY2025-26" for startYear 2025; wraps the century ("FY1999-00").
    static func label(startYear: Int) -> String {
        let endTwo = String(format: "%02d", (startYear + 1) % 100)
        return "FY\(startYear)-\(endTwo)"
    }

    /// The financial year containing `date`.
    static func of(_ date: Date, startMonth: Int = 7) -> Window {
        let cal = utcCalendar
        let comps = cal.dateComponents([.year, .month], from: date)
        let year = comps.year!
        let month = comps.month!
        let startYear = month >= startMonth ? year : year - 1
        let start = cal.date(from: DateComponents(year: startYear, month: startMonth, day: 1))!
        let end = cal.date(from: DateComponents(year: startYear + 1, month: startMonth, day: 1))!
        return Window(start: start, end: end, startYear: startYear, label: label(startYear: startYear))
    }

    /// True when `date` falls in FY `fyStartYear` ([start, nextStart)).
    static func isIn(_ date: Date, fyStartYear: Int, startMonth: Int = 7) -> Bool {
        let cal = utcCalendar
        let start = cal.date(from: DateComponents(year: fyStartYear, month: startMonth, day: 1))!
        let end = cal.date(from: DateComponents(year: fyStartYear + 1, month: startMonth, day: 1))!
        return date >= start && date < end
    }

    /// True when a "yyyy-MM-dd" string parses and falls in FY `fyStartYear`.
    static func isIn(_ iso: String, fyStartYear: Int, startMonth: Int = 7) -> Bool {
        guard let date = isoParser.date(from: iso) else { return false }
        return isIn(date, fyStartYear: fyStartYear, startMonth: startMonth)
    }
}
