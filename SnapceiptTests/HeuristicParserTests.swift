import Testing
import Foundation
@testable import Snapceipt

// ---------------------------------------------------------------------------
// Decodable types for the shared golden corpus.
// ---------------------------------------------------------------------------
private struct CorpusCase: Decodable {
    let name: String
    let ocrText: String
    let expect: CorpusExpect
    struct CorpusExpect: Decodable {
        let merchant: String
        let date: String?
        let total: Double
        let gst: Double
        let category: String
    }
}

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

    @Test func dotSeparatedDateNotPickedAsTotal() {
        let r = HeuristicParser.parse(lines(["Acme Pty Ltd", "28.05.2026", "TOTAL 9.00"]))
        #expect(r.total == Decimal(string: "9.00"))
    }

    @Test func taxiLineIsNotReadAsGst() {
        let r = HeuristicParser.parse(lines(["City Cabs", "Taxi fare 25.00", "TOTAL 25.00"]))
        // No printed GST line -> GST inferred as total/11, NOT 25.00 from "Taxi".
        #expect(r.tax == Decimal(string: "2.27"))
    }

    @Test func cashTenderedDoesNotBeatTotal() {
        let r = HeuristicParser.parse(lines(["Shop", "Item 4.50", "TOTAL 4.50", "CASH 50.00", "CHANGE 45.50"]))
        #expect(r.total == Decimal(string: "4.50"))
    }

    @Test func extractsLineItemsAndCategory() {
        let r = HeuristicParser.parse(lines(["The Coffee Club", "Flat White 4.50", "Muffin 5.50", "TOTAL 10.00"]))
        #expect(r.category == .meals)
        #expect(r.lineItems.count == 2)
        #expect(r.lineItems.first?.name == "Flat White")
        #expect(r.lineItems.first?.price == Decimal(string: "4.50"))
    }

    @Test func merchantSkipsHeaderNoise() {
        let r = HeuristicParser.parse(lines(["TAX INVOICE", "Bob's Hardware", "TOTAL 5.00"]))
        #expect(r.merchant == "Bob's Hardware")
    }

    @Test func confidenceRisesWithSignals() {
        let weak = HeuristicParser.parse(lines(["Zzz Pty Ltd", "9.00"]))
        let strong = HeuristicParser.parse(lines(["WOOLWORTHS", "TOTAL 11.00", "GST 1.00", "15/06/2026"]))
        #expect(weak.confidence <= 0.4)
        #expect(strong.confidence >= 0.6)
        #expect(strong.confidence <= 0.75)
    }

    // MARK: - Shared golden corpus (Task 8)

    /// Both Swift and TS parsers must satisfy test/fixtures/heuristic-receipts.json.
    /// The JSON is loaded via a #filePath-relative path (repo root = two parents up
    /// from SnapceiptTests/HeuristicParserTests.swift).  This works in the Xcode
    /// simulator / on-device because the test *source* file lives at the absolute
    /// path embedded by the compiler; the test sandbox can still read ordinary
    /// filesystem paths outside the app bundle.
    @Test func sharedCorpusMatches() throws {
        // SnapceiptTests/HeuristicParserTests.swift
        //   └─ SnapceiptTests/  (deletingLastPathComponent)
        //       └─ repo root/   (deletingLastPathComponent)
        //           └─ test/fixtures/heuristic-receipts.json
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        let fixtureURL = root.appendingPathComponent("test/fixtures/heuristic-receipts.json")
        let data = try Data(contentsOf: fixtureURL)
        let cases = try JSONDecoder().decode([CorpusCase].self, from: data)
        #expect(!cases.isEmpty, "corpus must not be empty")
        for c in cases {
            let r = HeuristicParser.parse(lines(c.ocrText.split(separator: "\n").map(String.init)))
            #expect(r.merchant == c.expect.merchant, "\(c.name): merchant")
            // Round to 2dp before comparing Decimal->Double to avoid binary float drift.
            let totalRounded = (NSDecimalNumber(decimal: r.total).doubleValue * 100).rounded() / 100
            #expect(totalRounded == c.expect.total, "\(c.name): total")
            if let tax = r.tax {
                let taxRounded = (NSDecimalNumber(decimal: tax).doubleValue * 100).rounded() / 100
                #expect(taxRounded == c.expect.gst, "\(c.name): gst")
            }
            #expect(r.category.rawValue == c.expect.category, "\(c.name): category")
        }
    }

    private func line(_ t: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> RecognizedLine {
        RecognizedLine(text: t, confidence: 0.9, boundingBox: CGRect(x: x, y: y, width: w, height: h))
    }

    // MARK: - Geometry tests (Task 7)

    /// Geometry is decisive: topmost line (largest maxY) is the merchant;
    /// when there is no explicit "total" line the biggest-font (tallest box) non-tender
    /// amount wins even when a distractor has a larger numeric value in a tiny box.
    @Test func geometryPicksTopLineAsMerchantAndBigFontTotal() {
        // Vision bottom-left origin: y=0.92 → near top of receipt.
        // 44.00 has a tall box (h=0.05) → big font → chosen as total.
        // 99.00 has a tiny box (h=0.015) → distractor; would win by value if geometry ignored.
        let ls = [
            line("WOOLWORTHS METRO", x: 0.1, y: 0.92, w: 0.6, h: 0.03),
            line("Milk 2.00",        x: 0.1, y: 0.60, w: 0.5, h: 0.02),
            line("44.00",            x: 0.7, y: 0.30, w: 0.2, h: 0.05),
            line("99.00",            x: 0.7, y: 0.10, w: 0.2, h: 0.015),
        ]
        let r = HeuristicParser.parse(ls)
        #expect(r.merchant == "WOOLWORTHS METRO")
        #expect(r.total == Decimal(string: "44.00"))
    }

    /// Real Vision OCR splits an item's name (left) and its price (right column)
    /// into two separate observations on the same visual row. The parser must pair
    /// them by geometry so line items are recognised when Smart Scan AI is OFF.
    @Test func pairsSplitNamePriceByRow() {
        let ls = [
            line("The Coffee Club", x: 0.1, y: 0.92,  w: 0.6,  h: 0.03),
            line("Flat White",      x: 0.1, y: 0.60,  w: 0.4,  h: 0.02),
            line("4.50",            x: 0.8, y: 0.605, w: 0.15, h: 0.02),
            line("Muffin",          x: 0.1, y: 0.50,  w: 0.4,  h: 0.02),
            line("5.50",            x: 0.8, y: 0.505, w: 0.15, h: 0.02),
            line("TOTAL",           x: 0.1, y: 0.30,  w: 0.3,  h: 0.02),
            line("10.00",           x: 0.8, y: 0.305, w: 0.15, h: 0.02),
        ]
        let r = HeuristicParser.parse(ls)
        #expect(r.lineItems.count == 2)
        #expect(r.lineItems.first?.name == "Flat White")
        #expect(r.lineItems.first?.price == Decimal(string: "4.50"))
        #expect(r.lineItems.last?.name == "Muffin")
        #expect(r.lineItems.last?.price == Decimal(string: "5.50"))
    }
}
