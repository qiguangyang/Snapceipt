import Foundation

enum BasPeriod: String, CaseIterable, Sendable {
    case quarterly
    case monthly
    var label: String { self == .quarterly ? "Quarterly" : "Monthly" }
}

/// AU BAS lodge/pay due dates. Pure + deterministic via an explicit calendar.
///
/// Note: deliberately uses Australia/Sydney rather than the UTC convention in
/// `FinancialYear.swift`. BAS deadlines are AU wall-clock dates (the 28th, the 21st)
/// so anchoring to the local zone keeps "is today the due date?" correct regardless of
/// the device's UTC offset. The two modules are each internally consistent.
enum BasSchedule {
    private static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return c
    }

    /// The next BAS due date on/after `on`.
    ///
    /// Quarterly: the ATO quarters END on 30 Sep / 31 Dec / 31 Mar / 30 Jun and the
    /// lodge/pay due date is the 28th of the month after the quarter END, except the
    /// Oct–Dec quarter which gets an extra month over Christmas:
    /// Sep→28 Oct, Dec→28 Feb (next year), Mar→28 Apr, Jun→28 Jul. We return the
    /// earliest such due date that falls on/after `on`'s day, so we never skip a
    /// deadline that is still in the future (e.g. on 10 Oct the imminent 28 Oct
    /// deadline is returned, not the following quarter's).
    static func nextDue(_ period: BasPeriod, on: Date) -> Date {
        let c = cal
        switch period {
        case .monthly:
            // 21st of the month after `on`'s month.
            let comps = c.dateComponents([.year, .month], from: on)
            let firstOfThis = c.date(from: comps)!
            let nextMonth = c.date(byAdding: .month, value: 1, to: firstOfThis)!
            return c.date(byAdding: .day, value: 20, to: nextMonth)! // 1st + 20 = 21st
        case .quarterly:
            // (quarterEndMonth, dueMonth, dueYearOffset): due is the 28th of `dueMonth`.
            // Oct–Dec (end month 12) is due 28 Feb of the FOLLOWING year (offset 1).
            let dues = [ (9, 10, 0), (12, 2, 1), (3, 4, 0), (6, 7, 0) ]
            let year = c.component(.year, from: on)
            let startOfOn = c.startOfDay(for: on)
            var candidates: [Date] = []
            for y in [year - 1, year, year + 1] {
                for (_, dueMonth, dueYearOffset) in dues {
                    var dc = DateComponents()
                    dc.year = y + dueYearOffset; dc.month = dueMonth; dc.day = 28
                    guard let due = c.date(from: dc) else { continue }
                    // Return the earliest due date on/after `on`'s day.
                    if due >= startOfOn { candidates.append(due) }
                }
            }
            return candidates.min()!
        }
    }
}
