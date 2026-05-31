import Testing
import Foundation
@testable import Snapceipt

@Suite("TransactionQuery")
struct TransactionQueryTests {
    private func iso(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    /// A small FY25-26 fixture: income + expenses across meals/fuel/software.
    private func fixture() -> [TransactionQuery.Txn] {
        [
            .init(txnDate: "2026-06-02", amountCents: 500_00, catKey: "income", deductiblePct: nil, gstCents: nil),
            .init(txnDate: "2026-06-05", amountCents: -120_00, catKey: "meals", deductiblePct: 50, gstCents: 10_91),
            .init(txnDate: "2026-06-10", amountCents: -80_00, catKey: "fuel", deductiblePct: 100, gstCents: 7_27),
            .init(txnDate: "2026-05-20", amountCents: -40_00, catKey: "software", deductiblePct: 100, gstCents: 3_64),
        ]
    }

    @Test("netSaved over the window = income - expense")
    func netSaved() {
        let w = Period.month.window(now: iso("2026-06-15"), startMonth: 7) // June
        let r = TransactionQuery.netSaved(fixture(), window: w)
        #expect(r.incomeCents == 500_00)
        #expect(r.expenseCents == 200_00)        // 120 + 80 (May software excluded)
        #expect(r.netCents == 300_00)
    }

    @Test("byCategory groups expenses desc, excludes income + out-of-window")
    func byCategory() {
        let w = Period.month.window(now: iso("2026-06-15"), startMonth: 7)
        let rows = TransactionQuery.byCategory(fixture(), window: w)
        #expect(rows.count == 2)
        #expect(rows[0].catKey == "meals" && rows[0].spendCents == 120_00)
        #expect(rows[1].catKey == "fuel" && rows[1].spendCents == 80_00)
    }

    @Test("monthlyTrend returns the last 5 calendar months anchored to now")
    func monthlyTrend() {
        let bars = TransactionQuery.monthlyTrend(fixture(), now: iso("2026-06-15"))
        #expect(bars.count == 5)                 // Feb..Jun
        #expect(bars.last?.label == "Jun")
        // June: income 500, expense 200
        #expect(bars.last?.income == 500.0)
        #expect(bars.last?.expense == 200.0)
        // May: expense 40 (software), income 0
        #expect(bars[3].label == "May")
        #expect(bars[3].expense == 40.0)
    }

    @Test("deductibleYTD sums txn deductible + F1 vehicle + WFH claims")
    func deductibleYTD() {
        let fy = Period.fy.window(now: iso("2026-06-15"), startMonth: 7) // FY2025-26
        // meals 120 @50% = 6000c ; fuel 80 @100% = 8000c ; software 40 @100% = 4000c
        // + vehicle claims 250_00 + wfh claims 90_00
        let r = TransactionQuery.deductibleYTD(
            fixture(), fyWindow: fy,
            vehicleYearClaims: [250_00],
            wfhClaims: [60_00, 30_00])
        #expect(r == 60_00 + 80_00 + 40_00 + 250_00 + 90_00)
    }

    @Test("gstYTD sums gstCents over FY expenses")
    func gstYTD() {
        let fy = Period.fy.window(now: iso("2026-06-15"), startMonth: 7)
        let r = TransactionQuery.gstYTD(fixture(), fyWindow: fy)
        #expect(r == 10_91 + 7_27 + 3_64)
    }

    @Test("empty input is all-zero / empty")
    func empties() {
        let w = Period.month.window(now: iso("2026-06-15"), startMonth: 7)
        #expect(TransactionQuery.netSaved([], window: w).netCents == 0)
        #expect(TransactionQuery.byCategory([], window: w).isEmpty)
        #expect(TransactionQuery.monthlyTrend([], now: iso("2026-06-15")).count == 5)
        #expect(TransactionQuery.gstYTD([], fyWindow: w) == 0)
    }
}
