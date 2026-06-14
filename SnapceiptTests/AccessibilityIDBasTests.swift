import Testing
@testable import Snapceipt

@Suite("AccessibilityID BAS ids")
struct AccessibilityIDBasTests {
    @Test("BAS + editor ids exist with stable string values")
    func ids() {
        #expect(AccessibilityID.reportsBasCard == "reports.bas.card")
        #expect(AccessibilityID.basScreen == "bas.screen")
        #expect(AccessibilityID.basPeriodStepper == "bas.period.stepper")
        #expect(AccessibilityID.basCopyG1 == "bas.copy.g1")
        #expect(AccessibilityID.basCopy1A == "bas.copy.1a")
        #expect(AccessibilityID.basCopy1B == "bas.copy.1b")
        #expect(AccessibilityID.basReconcileRowPrefix == "bas.reconcile.row.")
        #expect(AccessibilityID.basConfirmIncome == "bas.reconcile.confirmIncome")
        #expect(AccessibilityID.basPaygField == "bas.payg.field")
        #expect(AccessibilityID.basFullWorksheetToggle == "bas.fullWorksheet.toggle")
        #expect(AccessibilityID.basMarkLodged == "bas.markLodged")
        #expect(AccessibilityID.basExport == "bas.export")
        #expect(AccessibilityID.txnGstFreeToggle == "txn.gstFree.toggle")
        #expect(AccessibilityID.txnCapitalToggle == "txn.capital.toggle")
        #expect(AccessibilityID.txnGstAmountField == "txn.gstAmount.field")
        #expect(AccessibilityID.taxAbnHint == "tax.abn.hint")
    }
}
