import Testing
import Foundation
@testable import Snapceipt

struct HeuristicParserTests {
    private func lines(_ texts: [String]) -> [RecognizedLine] {
        texts.map { RecognizedLine(text: $0, confidence: 0.9, boundingBox: .zero) }
    }

    @Test("parses merchant, the total line amount, and an explicit GST line")
    func parsesTotalAndGST() {
        let p = HeuristicParser.parse(lines([
            "THE GROUNDS", "28/05/2026",
            "Flat White x2  9.00", "Big Brekkie 24.00",
            "GST 3.86", "TOTAL 42.50",
        ]))
        #expect(p.merchant == "THE GROUNDS")
        #expect(p.total == Decimal(string: "42.50"))
        #expect(p.tax == Decimal(string: "3.86"))
        #expect(p.currencyCode == "AUD")
    }

    @Test("ignores subtotal and prefers the TOTAL line")
    func ignoresSubtotal() {
        let p = HeuristicParser.parse(lines([
            "CAFE", "SUBTOTAL 100.00", "TOTAL 38.61",
        ]))
        #expect(p.total == Decimal(string: "38.61"))
    }

    @Test("infers AU GST as total/11 when no GST line is present")
    func infersGSTWhenMissing() {
        let p = HeuristicParser.parse(lines([
            "WOOLWORTHS", "TOTAL 22.00",
        ]))
        #expect(p.total == Decimal(string: "22.00"))
        // 22.00 / 11 = 2.00
        #expect(p.tax == Decimal(string: "2.00"))
    }

    @Test("defaults currency to AUD with no symbol")
    func defaultsAUD() {
        let p = HeuristicParser.parse(lines(["SHOP", "TOTAL 5.00"]))
        #expect(p.currencyCode == "AUD")
    }

    @Test func parsedReceiptCarriesCategoryAndConfidence() {
        let r = HeuristicParser.parse(lines(["WOOLWORTHS METRO", "TOTAL 12.00"]))
        // After Task 3: category defaults to .office (Task 5 will set .groceries), confidence in range.
        #expect(r.confidence >= 0.3 && r.confidence <= 0.75)
    }
}
