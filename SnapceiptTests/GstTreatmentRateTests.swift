import Testing
@testable import Snapceipt

@Suite("GstTreatment configurable rate")
struct GstTreatmentRateTests {
    @Test("default bp 1000 == legacy ÷11 (110.00 → 10.00)")
    func defaultEleven() {
        #expect(GstTreatment.derivedGstCents(totalCents: 11_000) == 1_000)
        #expect(GstTreatment.derivedGstCents(totalCents: 11_000, bp: 1000) == 1_000)
    }

    @Test("15% — 115.00 → 15.00")
    func fifteen() {
        #expect(GstTreatment.derivedGstCents(totalCents: 11_500, bp: 1500) == 1_500)
    }

    @Test("applyGstFree(false, bp:1500) derives at 15%")
    func applyFifteen() {
        let r = GstTreatment.applyGstFree(false, totalCents: 11_500, bp: 1500)
        #expect(r.gstCents == 1_500)
        #expect(r.gstSource == "derived")
    }

    @Test("applyGstFree(true) zeroes regardless of bp")
    func freeZeroes() {
        let r = GstTreatment.applyGstFree(true, totalCents: 11_500, bp: 1500)
        #expect(r.gstCents == 0)
        #expect(r.gstSource == nil)
    }
}
