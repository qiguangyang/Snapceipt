import Testing
@testable import Snapceipt

@Suite struct ReceiptCategoryHeuristicTests {
    @Test func mapsKnownMerchants() {
        #expect(ReceiptCategoryHeuristic.infer(merchant: "WOOLWORTHS 123", lineTexts: []) == .groceries)
        #expect(ReceiptCategoryHeuristic.infer(merchant: "Shell Express", lineTexts: []) == .fuel)
        #expect(ReceiptCategoryHeuristic.infer(merchant: "Bunnings", lineTexts: []) == .home)
        #expect(ReceiptCategoryHeuristic.infer(merchant: "Zzz Pty Ltd", lineTexts: []) == .office)
    }
}
