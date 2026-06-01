import Testing
import Foundation
@testable import Snapceipt

@Suite("InsightBuilder")
struct InsightBuilderTests {
    private func iso(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    private func fixtureThisMonth() -> [TransactionQuery.Txn] {
        [
            .init(txnDate: "2026-06-05", amountCents: -120_00, catKey: "meals", deductiblePct: 50, gstCents: nil),
            .init(txnDate: "2026-06-10", amountCents: -80_00, catKey: "fuel", deductiblePct: 100, gstCents: nil),
        ]
    }
    private func fixturePrevMonth() -> [TransactionQuery.Txn] {
        [ .init(txnDate: "2026-05-09", amountCents: -300_00, catKey: "meals", deductiblePct: 50, gstCents: nil) ]
    }

    @Test("empty data -> onboarding fallback")
    func emptyFallback() {
        let w = Period.month.window(now: iso("2026-06-15"), startMonth: 7)
        let prev = Period.month.window(now: iso("2026-05-15"), startMonth: 7)
        let s = InsightBuilder.insight(mode: .business, txns: [], window: w, prevWindow: prev)
        #expect(s == "Add a few receipts and your insights will appear here.")
    }

    @Test("names the top category this period with its amount")
    func topCategory() {
        let w = Period.month.window(now: iso("2026-06-15"), startMonth: 7)
        let prev = Period.month.window(now: iso("2026-05-15"), startMonth: 7)
        let s = InsightBuilder.insight(mode: .business, txns: fixtureThisMonth(),
                                       window: w, prevWindow: prev, periodWord: Period.month.word)
        #expect(s.contains("Meals & Coffee"))
        #expect(s.contains("$120.00"))
        #expect(s.contains("this month"))
    }

    @Test("reports a period-over-period delta when prior data exists")
    func delta() {
        let w = Period.month.window(now: iso("2026-06-15"), startMonth: 7)
        let prev = Period.month.window(now: iso("2026-05-15"), startMonth: 7)
        let all = fixtureThisMonth() + fixturePrevMonth()
        // This month spend 200, last month 300 -> spent 100 less.
        let s = InsightBuilder.insight(mode: .personal, txns: all, window: w, prevWindow: prev,
                                       periodWord: Period.month.word)
        #expect(s.contains("less"))
        #expect(s.contains("$100.00"))
        #expect(s.contains("last month"))
    }

    @Test("period word follows the selected period — FY window says year, not month")
    func periodWordFollowsWindow() {
        let w = Period.fy.window(now: iso("2026-06-15"), startMonth: 7)
        let prev = Period.fy.window(now: iso("2025-06-15"), startMonth: 7)
        let s = InsightBuilder.insight(mode: .personal, txns: fixtureThisMonth(),
                                       window: w, prevWindow: prev, periodWord: Period.fy.word)
        #expect(s.contains("this year"))
        #expect(!s.contains("this month"))
    }
}
