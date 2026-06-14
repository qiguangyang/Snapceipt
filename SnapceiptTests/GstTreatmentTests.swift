import Testing
import Foundation
@testable import Snapceipt

@Suite("GstTreatment authority rule")
struct GstTreatmentTests {
    @Test("gstFree=true zeroes gstCents and nils gstSource")
    func gstFreeZeroes() {
        let r = GstTreatment.applyGstFree(true, totalCents: 33_000)
        #expect(r.gstCents == 0)
        #expect(r.gstSource == nil)
    }

    @Test("flipping back to taxable re-derives round(total/11) as derived")
    func flipBackDerives() {
        // |amount| = 110_000; round(110000/11) = 10_000.
        let r = GstTreatment.applyGstFree(false, totalCents: 110_000)
        #expect(r.gstCents == 10_000)
        #expect(r.gstSource == "derived")
    }

    @Test("typing an exact GST amount marks it manual")
    func typedIsManual() {
        let r = GstTreatment.applyManualGst(5_00)
        #expect(r.gstCents == 5_00)
        #expect(r.gstSource == "manual")
    }

    @Test("derive rounds half up at the .5 boundary")
    func deriveHalfUp() {
        // total 5 → 5/11 = 0.4545 → rounds to 0; total 6 → 0.545 → 1.
        #expect(GstTreatment.applyGstFree(false, totalCents: 5).gstCents == 0)
        #expect(GstTreatment.applyGstFree(false, totalCents: 6).gstCents == 1)
    }

    @Test("confirming income marks provenance manual (the income-reviewed signal)")
    func confirmIncome() {
        let r = GstTreatment.confirmIncome()
        #expect(r.gstSource == "manual")
        #expect(r.gstCents == nil)   // income GST is not split per-txn; provenance only
    }
}
