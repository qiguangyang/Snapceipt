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
}
