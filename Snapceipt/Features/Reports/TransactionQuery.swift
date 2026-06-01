import Foundation

/// Pure SwiftData-free transaction aggregation for Reports. Callers pass plain
/// `Txn` snapshots + a `Period.Window` (or injected `now`) so this stays
/// unit-testable (no hidden `Date()`). All amounts are signed cents (expense < 0,
/// income > 0); dates are "yyyy-MM-dd" UTC. (spec §4.6)
enum TransactionQuery {
    /// A minimal transaction snapshot for aggregation.
    struct Txn: Equatable {
        let txnDate: String       // "yyyy-MM-dd"
        let amountCents: Int      // signed
        let catKey: String        // CategoryKey raw value or "custom"
        let deductiblePct: Int?
        let gstCents: Int?
    }

    struct Net: Equatable {
        let incomeCents: Int
        let expenseCents: Int
        let netCents: Int
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
        return c
    }

    /// True when `txnDate` parses and falls in [window.start, window.end).
    private static func inWindow(_ txnDate: String, _ window: Period.Window) -> Bool {
        guard let d = isoParser.date(from: txnDate) else { return false }
        return d >= window.start && d < window.end
    }

    /// income = Σ amount>0; expense = Σ −amount over amount<0; net = income − expense.
    static func netSaved(_ txns: [Txn], window: Period.Window) -> Net {
        var income = 0, expense = 0
        for t in txns where inWindow(t.txnDate, window) {
            if t.amountCents > 0 { income += t.amountCents }
            else if t.amountCents < 0 { expense += -t.amountCents }
        }
        return Net(incomeCents: income, expenseCents: expense, netCents: income - expense)
    }

    /// The last 5 calendar months anchored to `now`, each {label, income, expense}.
    /// Period-independent (drives the fixed `BarPair`).
    static func monthlyTrend(_ txns: [Txn], now: Date) -> [BarPairDatum] {
        let cal = utcCalendar
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let labelFmt = DateFormatter()
        labelFmt.locale = Locale(identifier: "en_AU")
        labelFmt.timeZone = TimeZone(identifier: "UTC")
        labelFmt.dateFormat = "MMM"

        var bars: [BarPairDatum] = []
        for offset in stride(from: -4, through: 0, by: 1) {
            let mStart = cal.date(byAdding: .month, value: offset, to: monthStart)!
            let mEnd = cal.date(byAdding: .month, value: 1, to: mStart)!
            var income = 0.0, expense = 0.0
            for t in txns {
                guard let d = isoParser.date(from: t.txnDate), d >= mStart, d < mEnd else { continue }
                if t.amountCents > 0 { income += Double(t.amountCents) / 100.0 }
                else if t.amountCents < 0 { expense += Double(-t.amountCents) / 100.0 }
            }
            bars.append(BarPairDatum(label: labelFmt.string(from: mStart),
                                     income: income, expense: expense))
        }
        return bars
    }

    /// Expenses grouped by catKey, Σ −amount, sorted desc.
    static func byCategory(_ txns: [Txn], window: Period.Window) -> [(catKey: String, spendCents: Int)] {
        var sums: [String: Int] = [:]
        for t in txns where inWindow(t.txnDate, window) && t.amountCents < 0 {
            sums[t.catKey, default: 0] += -t.amountCents
        }
        return sums.map { ($0.key, $0.value) }
            .sorted { a, b in a.spendCents == b.spendCents ? a.catKey < b.catKey : a.spendCents > b.spendCents }
    }

    /// Σ round(−amount × pct/100) over FY expenses (when pct != nil) + Σ vehicle
    /// claims + Σ wfh claims. FY-to-date; period-independent.
    static func deductibleYTD(_ txns: [Txn], fyWindow: Period.Window,
                              vehicleYearClaims: [Int], wfhClaims: [Int]) -> Int {
        var total = 0
        for t in txns where inWindow(t.txnDate, fyWindow) && t.amountCents < 0 {
            guard let pct = t.deductiblePct else { continue }
            total += Int((Double(-t.amountCents) * Double(pct) / 100.0).rounded())
        }
        total += vehicleYearClaims.reduce(0, +)
        total += wfhClaims.reduce(0, +)
        return total
    }

    /// Σ gstCents over FY expenses. FY-to-date.
    static func gstYTD(_ txns: [Txn], fyWindow: Period.Window) -> Int {
        var total = 0
        for t in txns where inWindow(t.txnDate, fyWindow) && t.amountCents < 0 {
            total += t.gstCents ?? 0
        }
        return total
    }
}
