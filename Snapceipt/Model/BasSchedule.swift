import Foundation

enum BasPeriod: String, CaseIterable, Sendable {
    case quarterly
    case monthly
    var label: String { self == .quarterly ? "Quarterly" : "Monthly" }
}

/// AU BAS lodge/pay due dates. Pure + deterministic (UTC-stable via an explicit calendar).
enum BasSchedule {
    private static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return c
    }

    /// The next BAS due date on/after `on`.
    ///
    /// Quarterly: the ATO quarters END on 30 Sep / 31 Dec / 31 Mar / 30 Jun and the
    /// lodge/pay due date is the 28th of the month after the quarter END
    /// (Sep→28 Oct, Dec→28 Jan, Mar→28 Apr, Jun→28 Jul). We return the due date for
    /// the next quarter to END strictly after `on` — i.e. a date in the current
    /// quarter advances to that quarter's due, but once a quarter has ended we move on
    /// to the next quarter's due even if the just-ended quarter's due has not yet passed.
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
            // (quarterEndMonth, dueMonth): due is the 28th of the month AFTER the quarter end.
            let dues = [ (9, 10), (12, 1), (3, 4), (6, 7) ]
            let year = c.component(.year, from: on)
            let startOfOn = c.startOfDay(for: on)
            var candidates: [Date] = []
            for y in [year - 1, year, year + 1] {
                for (endMonth, dueMonth) in dues {
                    // The last day of the quarter-end month for year y.
                    var qe = DateComponents(); qe.year = y; qe.month = endMonth + 1; qe.day = 0
                    guard let quarterEnd = c.date(from: qe) else { continue }
                    // Due is the 28th of the month after the quarter end (Dec→Jan rolls a year).
                    let dueYear = dueMonth < endMonth ? y + 1 : y
                    var dc = DateComponents(); dc.year = dueYear; dc.month = dueMonth; dc.day = 28
                    guard let due = c.date(from: dc) else { continue }
                    // Only consider quarters that END strictly after `on`'s day.
                    if quarterEnd >= startOfOn { candidates.append(due) }
                }
            }
            return candidates.min()!
        }
    }
}
