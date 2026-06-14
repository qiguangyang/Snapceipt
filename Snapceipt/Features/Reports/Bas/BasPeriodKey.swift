import Foundation

/// The stable per-period storage key (spec §4.6). Quarterly → "<fyStartYear>Q<n>"
/// (e.g. 2025Q4 = Apr–Jun FY2025-26); monthly → "<calendarYear>M<mm>" (e.g. 2026M04).
/// Derived from the period WINDOW's start so it matches whatever window the stepper
/// navigated to (no hidden Date()).
enum BasPeriodKey {
    private static var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    /// AU-FY quarter index 1...4 of `month` for FY starting `startMonth`.
    private static func quarterIndex(month: Int, startMonth: Int) -> Int {
        let offset = (month - startMonth + 12) % 12
        return offset / 3 + 1
    }

    static func make(window: Period.Window, basPeriod: BasPeriod, startMonth: Int) -> String {
        let comps = utcCal.dateComponents([.year, .month], from: window.start)
        let year = comps.year!, month = comps.month!
        switch basPeriod {
        case .monthly:
            return String(format: "%dM%02d", year, month)
        case .quarterly:
            let qi = quarterIndex(month: month, startMonth: startMonth)
            // FY start year: if the quarter-start month is on/after startMonth it is
            // the same calendar year; otherwise the FY started the previous year.
            let fyStartYear = month >= startMonth ? year : year - 1
            return "\(fyStartYear)Q\(qi)"
        }
    }
}
