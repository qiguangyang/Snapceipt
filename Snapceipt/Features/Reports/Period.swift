import Foundation

/// The Reports period control. `month`/`quarter`/`fy` rescope the donut + the
/// headline net figure. Period = the CURRENT month / quarter / FY of an INJECTED
/// `now` (no past-period navigation in v1, no hidden `Date()`). All dates are UTC
/// to match the app's "yyyy-MM-dd" handling (Formatters.swift / FinancialYear).
enum Period: String, CaseIterable, Equatable {
    case month
    case quarter
    case fy

    /// One period's window + display label.
    struct Window: Equatable {
        let start: Date    // inclusive, 00:00 UTC
        let end: Date      // exclusive, 00:00 UTC
        let label: String  // "June 2026" / "Apr–Jun 2026" / "FY2025-26"
    }

    private static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// AU-FY quarter index 1...4 of `month` (Q1 Jul-Sep, Q2 Oct-Dec, Q3 Jan-Mar, Q4 Apr-Jun).
    private static func quarterIndex(month: Int) -> Int {
        // Months Jul(7)..Jun(6) -> 0..11 from FY start; /3 -> 0..3 -> +1.
        let offset = (month - 7 + 12) % 12
        return offset / 3 + 1
    }

    /// The window for this period containing `now`.
    func window(now: Date, startMonth: Int = 7) -> Window {
        let cal = Period.utcCalendar
        let comps = cal.dateComponents([.year, .month], from: now)
        let year = comps.year!
        let month = comps.month!

        switch self {
        case .month:
            let start = cal.date(from: DateComponents(year: year, month: month, day: 1))!
            let end = cal.date(byAdding: .month, value: 1, to: start)!
            return Window(start: start, end: end, label: Period.monthLabel(start))
        case .quarter:
            // The quarter's first month is the FY-quarter start nearest <= now.
            let qi = Period.quarterIndex(month: month)              // 1..4
            let firstMonthOfFY = startMonth                          // 7
            let qStartMonthRaw = (firstMonthOfFY - 1 + (qi - 1) * 3) % 12 + 1 // 7,10,1,4
            // Resolve the calendar year of the quarter start relative to `now`.
            let startYearAdjust = (month >= qStartMonthRaw) ? 0 : -1
            let qStart = cal.date(from: DateComponents(year: year + startYearAdjust,
                                                       month: qStartMonthRaw, day: 1))!
            let qEnd = cal.date(byAdding: .month, value: 3, to: qStart)!
            return Window(start: qStart, end: qEnd, label: Period.quarterLabel(qStart, qEnd))
        case .fy:
            let fy = FinancialYear.of(now, startMonth: startMonth)
            return Window(start: fy.start, end: fy.end, label: fy.label)
        }
    }

    /// The bare period noun for insight copy ("month" / "quarter" / "year"), so the
    /// insight's "this <word>" / "last <word>" matches the window it summarises.
    var word: String {
        switch self {
        case .month: return "month"
        case .quarter: return "quarter"
        case .fy: return "year"
        }
    }

    /// The trend-card caption: "This month" / "This quarter" / "FY2025-26".
    func headline(now: Date, startMonth: Int = 7) -> String {
        switch self {
        case .month: return "This month"
        case .quarter: return "This quarter"
        case .fy: return FinancialYear.of(now, startMonth: startMonth).label
        }
    }

    private static let monthFmt: DateFormatter = makeFmt("MMMM yyyy")
    private static let monAbbrFmt: DateFormatter = makeFmt("MMM")
    private static let yearFmt: DateFormatter = makeFmt("yyyy")

    private static func makeFmt(_ fmt: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = fmt
        return f
    }

    private static func monthLabel(_ start: Date) -> String { monthFmt.string(from: start) }

    /// "Apr–Jun 2026" — abbreviated start/end month + the END month's year.
    private static func quarterLabel(_ start: Date, _ end: Date) -> String {
        let cal = utcCalendar
        let lastMonth = cal.date(byAdding: .month, value: -1, to: end)! // inclusive last month
        let a = monAbbrFmt.string(from: start)
        let b = monAbbrFmt.string(from: lastMonth)
        let yr = yearFmt.string(from: lastMonth)
        return "\(a)\u{2013}\(b) \(yr)"
    }
}
