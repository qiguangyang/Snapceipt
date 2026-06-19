import Testing
@testable import Snapceipt

@Suite("QuoteTotals configurable GST rate")
struct QuoteTotalsRateTests {
    private func lines(_ pairs: [(Int, Int)]) -> [QuoteTotals.Line] {
        pairs.map { QuoteTotals.Line(quantity: $0.0, unitPriceCents: $0.1) }
    }

    @Test("Exclusive 10% (default + explicit) — 400.00 → gst 40.00, total 440.00")
    func excTen() {
        let t = QuoteTotals.compute(lineItems: lines([(1, 40_000)]), gstEnabled: true)
        #expect(t == (40_000, 4_000, 44_000))
        let t2 = QuoteTotals.compute(lineItems: lines([(1, 40_000)]), gstEnabled: true, gstRateBp: 1000)
        #expect(t2 == (40_000, 4_000, 44_000))
    }

    @Test("Exclusive 15% — 200.00 → gst 30.00, total 230.00")
    func excFifteen() {
        let t = QuoteTotals.compute(lineItems: lines([(1, 20_000)]), gstEnabled: true, gstRateBp: 1500)
        #expect(t == (20_000, 3_000, 23_000))
    }

    @Test("Exclusive custom 12.5% — 200.00 → gst 25.00, total 225.00")
    func excCustom() {
        let t = QuoteTotals.compute(lineItems: lines([(1, 20_000)]), gstEnabled: true, gstRateBp: 1250)
        #expect(t == (20_000, 2_500, 22_500))
    }

    @Test("Inclusive 10% — gross 110.00 → gst 10.00, subtotal 100.00")
    func incTen() {
        let t = QuoteTotals.compute(lineItems: lines([(1, 11_000)]), gstEnabled: true,
                                    gstInclusive: true, gstRateBp: 1000)
        #expect(t == (10_000, 1_000, 11_000))
    }

    @Test("Inclusive 15% — gross 115.00 → gst 15.00, subtotal 100.00")
    func incFifteen() {
        let t = QuoteTotals.compute(lineItems: lines([(1, 11_500)]), gstEnabled: true,
                                    gstInclusive: true, gstRateBp: 1500)
        #expect(t == (10_000, 1_500, 11_500))
    }

    @Test("null rate ⇒ 10%")
    func nullDefaultsTen() {
        let t = QuoteTotals.compute(lineItems: lines([(1, 40_000)]), gstEnabled: true, gstRateBp: nil)
        #expect(t == (40_000, 4_000, 44_000))
    }

    @Test("gst disabled ignores rate")
    func disabled() {
        let t = QuoteTotals.compute(lineItems: lines([(1, 40_000)]), gstEnabled: false, gstRateBp: 1500)
        #expect(t == (40_000, 0, 40_000))
    }
}
