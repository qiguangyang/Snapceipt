import Testing
@testable import Snapceipt

struct TaxLabelTests {
    @Test("receiptTaxLabel localizes the tax name per currency")
    func labelsPerCurrency() {
        #expect(receiptTaxLabel(for: "AUD") == "GST")
        #expect(receiptTaxLabel(for: "NZD") == "GST")
        #expect(receiptTaxLabel(for: "USD") == "Sales tax")
        #expect(receiptTaxLabel(for: "CAD") == "GST/HST")
        #expect(receiptTaxLabel(for: "usd") == "Sales tax") // case-insensitive
        #expect(receiptTaxLabel(for: "GBP") == "GST")        // unsupported → fallback
    }
}
