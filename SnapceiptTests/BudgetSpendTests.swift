import Testing
import Foundation
@testable import Snapceipt

@Suite("BudgetSpend")
struct BudgetSpendTests {
    private func iso(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    private let txns: [BudgetSpend.Txn] = [
        // June 2026
        .init(txnDate: "2026-06-02", amountCents: -120_00, categoryId: "cat-meals"),
        .init(txnDate: "2026-06-05", amountCents: -80_00,  categoryId: "cat-fuel"),
        .init(txnDate: "2026-06-06", amountCents:  500_00, categoryId: "cat-income"), // income excluded
        // May 2026 (other month — excluded for June target)
        .init(txnDate: "2026-05-30", amountCents: -999_00, categoryId: "cat-meals"),
    ]

    @Test("monthKey is the YYYY-MM of an injected now (UTC)")
    func monthKeyOfNow() {
        #expect(BudgetSpend.monthKey(for: iso("2026-06-15")) == "2026-06")
        #expect(BudgetSpend.monthKey(for: iso("2026-01-01")) == "2026-01")
    }

    @Test("whole-profile budget sums every expense in the target month")
    func wholeProfile() {
        let b = Budget(userId: "u1", profileId: "p1", categoryId: nil,
                       label: "Everything", capCents: 600_00)
        #expect(BudgetSpend.spent(budget: b, txns: txns, now: iso("2026-06-15")) == 200_00) // 120 + 80
    }

    @Test("per-category budget only sums that category in the target month")
    func perCategory() {
        let b = Budget(userId: "u1", profileId: "p1", categoryId: "cat-meals",
                       label: "Meals", capCents: 200_00)
        #expect(BudgetSpend.spent(budget: b, txns: txns, now: iso("2026-06-15")) == 120_00)
    }

    @Test("a fixed monthKey overrides the injected now")
    func fixedMonthKey() {
        let b = Budget(userId: "u1", profileId: "p1", categoryId: "cat-meals",
                       label: "Meals", monthKey: "2026-05", capCents: 200_00)
        #expect(BudgetSpend.spent(budget: b, txns: txns, now: iso("2026-06-15")) == 999_00)
    }

    @Test("over-cap detection compares spent to cap (strictly greater)")
    func overCap() {
        let b = Budget(userId: "u1", profileId: "p1", categoryId: nil,
                       label: "Tiny", capCents: 100_00)
        let s = BudgetSpend.spent(budget: b, txns: txns, now: iso("2026-06-15")) // 200_00
        #expect(s > b.capCents)
    }
}
