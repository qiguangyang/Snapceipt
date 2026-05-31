import Foundation

/// Pure, SwiftData-free budget-spend math. Mirrors the backend §4.3 contract EXACTLY
/// so on-device and server numbers agree: spent = Σ magnitude of expenses
/// (amountCents < 0) in the budget's target month, scoped to its category (nil = all).
/// `now` is INJECTED (no hidden Date()/Calendar.current) — that class of bug bit capture.
enum BudgetSpend {
    /// A minimal transaction snapshot for budget aggregation. `categoryId` matches the
    /// Transaction column the budget links by (Budget.categoryId), NOT the catKey.
    struct Txn: Equatable {
        let txnDate: String        // "yyyy-MM-dd"
        let amountCents: Int       // signed; expense < 0
        let categoryId: String?
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// "YYYY-MM" of `now` in UTC (the recurring-budget target month).
    static func monthKey(for now: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month], from: now)
        return String(format: "%04d-%02d", c.year!, c.month!)
    }

    /// Spent cents for `budget` over `txns`. Target month = `budget.monthKey` when set,
    /// else the current calendar month (UTC) of `now`.
    static func spent(budget: Budget, txns: [Txn], now: Date) -> Int {
        let target = budget.monthKey ?? monthKey(for: now)
        var total = 0
        for t in txns where t.amountCents < 0 {
            guard t.txnDate.hasPrefix(target) else { continue }       // substr(txnDate,1,7) == target
            if let cat = budget.categoryId, t.categoryId != cat { continue }
            total += -t.amountCents
        }
        return total
    }
}
