import Testing
import Foundation
@testable import Snapceipt

@Suite("BAS reconciliation")
struct BasReconciliationTests {
    private func item(_ amount: Int, gstFree: Bool = false, gstSource: String? = nil,
                      gstCents: Int? = nil, confirmed: Bool = false) -> BasReconciliation.Item {
        BasReconciliation.Item(id: UUID().uuidString, amountCents: amount, gstFree: gstFree,
                               gstSource: gstSource, gstCents: gstCents, incomeConfirmed: confirmed)
    }

    @Test("estimated GST = taxable expenses whose gstSource == derived")
    func estimated() {
        let items = [item(-110_00, gstSource: "derived"), item(-50_00, gstSource: "manual"),
                     item(-30_00, gstFree: true, gstSource: nil)]
        #expect(BasReconciliation.estimatedGstCount(items) == 1)
    }

    @Test("income-to-confirm gates the firm headline")
    func incomeGate() {
        let unconfirmed = [item(500_00, confirmed: false)]
        #expect(BasReconciliation.incomeToConfirmCount(unconfirmed) == 1)
        #expect(BasReconciliation.isHeadlineEstimated(unconfirmed) == true)
        let confirmed = [item(500_00, confirmed: true)]
        #expect(BasReconciliation.incomeToConfirmCount(confirmed) == 0)
        #expect(BasReconciliation.isHeadlineEstimated(confirmed) == false)
    }

    @Test("printed-line discrepancy flags when |printed − round(total/11)| > max(2c, 1% of total)")
    func discrepancy() {
        // total 100_00 → round/11 = 9_09; threshold = max(2, 1% of 100_00=100) = 100c.
        // printed 9_50 → |950 − 909| = 41 ≤ 100 → NOT flagged.
        #expect(BasReconciliation.isPrintedDiscrepant(totalCents: 100_00, printedGstCents: 9_50) == false)
        // printed 12_00 → |1200 − 909| = 291 > 100 → flagged.
        #expect(BasReconciliation.isPrintedDiscrepant(totalCents: 100_00, printedGstCents: 12_00) == true)
        // tiny total 100c → round/11 = 9; threshold = max(2, 1%=1) = 2c.
        // printed 12 → |12 − 9| = 3 > 2 → flagged.
        #expect(BasReconciliation.isPrintedDiscrepant(totalCents: 100, printedGstCents: 12) == true)
    }
}
