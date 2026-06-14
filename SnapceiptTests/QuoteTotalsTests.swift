import Testing
import Foundation
@testable import Snapceipt

@Suite("QuoteTotals.compute")
struct QuoteTotalsTests {
    private func line(_ qty: Int, _ unit: Int) -> QuoteTotals.Line {
        QuoteTotals.Line(quantity: qty, unitPriceCents: unit)
    }

    @Test("subtotal sums quantity * unitPriceCents across lines")
    func subtotal() {
        let r = QuoteTotals.compute(lineItems: [line(2, 5_00), line(3, 10_00)], gstEnabled: false)
        #expect(r.subtotal == 40_00)   // 2*500 + 3*1000
        #expect(r.gst == 0)
        #expect(r.total == 40_00)
    }

    @Test("GST is 10% of subtotal, rounded to the nearest cent")
    func gstRounding() {
        let r = QuoteTotals.compute(lineItems: [line(1, 33_33)], gstEnabled: true)
        #expect(r.subtotal == 33_33)
        #expect(r.gst == 3_33)
        #expect(r.total == 36_66)
    }

    @Test("GST rounds half up at the .5 boundary")
    func gstHalfUp() {
        let r = QuoteTotals.compute(lineItems: [line(1, 5)], gstEnabled: true)
        #expect(r.gst == 1)
        #expect(r.total == 6)
    }

    @Test("GST off yields zero gst and total == subtotal")
    func gstOff() {
        let r = QuoteTotals.compute(lineItems: [line(1, 100_00)], gstEnabled: false)
        #expect(r.gst == 0)
        #expect(r.total == 100_00)
    }

    @Test("empty line items yield all zeros")
    func empty() {
        let r = QuoteTotals.compute(lineItems: [] as [QuoteTotals.Line], gstEnabled: true)
        #expect(r.subtotal == 0 && r.gst == 0 && r.total == 0)
    }

    // MARK: - GST inclusive

    @Test("GST inclusive: entered prices already contain GST; total stays the entered sum")
    func inclusiveBreakdown() {
        // 165 + 45 = 210.00 entered (GST-inclusive). GST = round(21000 * 0.1/1.1) = 1909.
        let r = QuoteTotals.compute(lineItems: [line(1, 165_00), line(1, 45_00)],
                                    gstEnabled: true, gstInclusive: true)
        #expect(r.total == 210_00)        // unchanged from the entered sum
        #expect(r.gst == 19_09)           // embedded GST = round(210/11)
        #expect(r.subtotal == 190_91)     // ex-GST base = total - gst
        #expect(r.subtotal + r.gst == r.total)   // invariant
    }

    @Test("GST inclusive vs exclusive give the same gross only when inclusive total == exclusive subtotal")
    func inclusiveVsExclusive() {
        let incl = QuoteTotals.compute(lineItems: [line(1, 110_00)], gstEnabled: true, gstInclusive: true)
        #expect(incl.total == 110_00)
        #expect(incl.gst == 10_00)        // round(11000 * 0.1/1.1) = 1000
        #expect(incl.subtotal == 100_00)

        let excl = QuoteTotals.compute(lineItems: [line(1, 110_00)], gstEnabled: true, gstInclusive: false)
        #expect(excl.subtotal == 110_00)
        #expect(excl.gst == 11_00)
        #expect(excl.total == 121_00)
    }

    @Test("GST inclusive is ignored when GST is disabled")
    func inclusiveIgnoredWhenGstOff() {
        let r = QuoteTotals.compute(lineItems: [line(1, 100_00)], gstEnabled: false, gstInclusive: true)
        #expect(r.subtotal == 100_00 && r.gst == 0 && r.total == 100_00)
    }
}
