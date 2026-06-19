import Foundation
import Testing
@testable import Snapceipt

@Suite("BasHistory")
struct BasHistoryTests {
    private func now(_ s: String = "2026-05-15") -> Date {   // Apr–Jun 2026 = 2025Q4
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }
    private func txn(_ amount: Int, _ date: String, gstFree: Bool = false, capital: Bool = false) -> BasEngine.Txn {
        BasEngine.Txn(amountCents: amount, gstFree: gstFree, capital: capital, txnDate: date)
    }
    private let none: (String) -> BasLocalStore.Snapshot? = { _ in nil }

    @Test("contiguous rows from the current period back to the earliest period with data")
    func rowsSpanData() {
        let txns = [txn(1_100_000, "2026-05-01"),   // current quarter 2025Q4
                    txn(-110_000, "2026-02-10")]    // prior quarter 2025Q3
        let rows = BasHistory.build(txns: txns, lodged: none, gstRegistered: true,
                                    basPeriod: .quarterly, startMonth: 7, now: now())
        #expect(rows.map(\.periodKey) == ["2025Q4", "2025Q3"])   // most-recent first
        #expect(rows[0].offset == 0)
        #expect(rows[0].netGstCents == 100_000)                  // 1A on 1.1M income, no purchases
        #expect(rows[1].offset == -1)
        #expect(rows[1].netGstCents == -10_000)                  // 1B on a 110k purchase
    }

    @Test("status: current period is Due; a past unmarked period is Not-marked-lodged")
    func statusClassification() {
        let txns = [txn(1_100_000, "2026-05-01"), txn(-110_000, "2026-02-10")]
        let rows = BasHistory.build(txns: txns, lodged: none, gstRegistered: true,
                                    basPeriod: .quarterly, startMonth: 7, now: now())
        if case .due = rows[0].status {} else { Issue.record("current period should be .due") }
        if case .notMarkedLodged = rows[1].status {} else { Issue.record("past unmarked should be .notMarkedLodged") }
    }

    @Test("status: a lodged period reads lodged; drift flips when GST figures change")
    func lodgedAndDrift() {
        let txns = [txn(-110_000, "2026-02-10")]   // 2025Q3: oneB = 10_000, net = -10_000
        let clean = BasLocalStore.Snapshot(g1: 0, oneA: 0, oneB: 10_000, netGst: -10_000,
                                           payg: 0, total: -10_000, lodgedAtMs: 1_700_000_000_000)
        let drifted = BasLocalStore.Snapshot(g1: 0, oneA: 0, oneB: 5_000, netGst: -5_000,
                                             payg: 0, total: -5_000, lodgedAtMs: 1_700_000_000_000)
        let rowsClean = BasHistory.build(txns: txns, lodged: { $0 == "2025Q3" ? clean : nil },
                                         gstRegistered: true, basPeriod: .quarterly, startMonth: 7, now: now())
        #expect(rowsClean.first { $0.periodKey == "2025Q3" }?.status == .lodged(atMs: 1_700_000_000_000, drifted: false))
        let rowsDrift = BasHistory.build(txns: txns, lodged: { $0 == "2025Q3" ? drifted : nil },
                                         gstRegistered: true, basPeriod: .quarterly, startMonth: 7, now: now())
        #expect(rowsDrift.first { $0.periodKey == "2025Q3" }?.status == .lodged(atMs: 1_700_000_000_000, drifted: true))
    }

    @Test("empty data → just the current period")
    func emptyIsCurrentOnly() {
        let rows = BasHistory.build(txns: [], lodged: none, gstRegistered: true,
                                    basPeriod: .quarterly, startMonth: 7, now: now())
        #expect(rows.count == 1)
        #expect(rows[0].offset == 0)
    }

    @Test("data older than the 3-year cap is excluded (earliestOffset clamps)")
    func capExcludesAncientData() {
        // 13 quarters back from 2025Q4 is beyond the 12-quarter cap (floor = -11).
        let txns = [txn(1_100_000, "2026-05-01"),   // current
                    txn(-110_000, "2023-02-10")]    // ~13 quarters back → beyond cap
        #expect(BasHistory.earliestOffset(txns: txns, lodged: none, basPeriod: .quarterly,
                                          startMonth: 7, now: now()) == 0)
        let rows = BasHistory.build(txns: txns, lodged: none, gstRegistered: true,
                                    basPeriod: .quarterly, startMonth: 7, now: now())
        #expect(rows.count == 1)   // only the current period; the ancient txn is past the cap
    }
}
