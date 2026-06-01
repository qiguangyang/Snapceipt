import Testing
import Foundation
@testable import Snapceipt

@Suite("BarcodeRenderer")
struct BarcodeRendererTests {

    // MARK: - Task 1: BarcodeFormat enum + LoyaltyCard.format bridge

    @Test("BarcodeFormat raw values match the stored strings")
    func formatRawValues() {
        #expect(LoyaltyCard.BarcodeFormat.code128.rawValue == "code128")
        #expect(LoyaltyCard.BarcodeFormat.ean13.rawValue == "ean13")
        #expect(LoyaltyCard.BarcodeFormat.qr.rawValue == "qr")
        #expect(LoyaltyCard.BarcodeFormat.aztec.rawValue == "aztec")
        #expect(LoyaltyCard.BarcodeFormat.pdf417.rawValue == "pdf417")
        #expect(LoyaltyCard.BarcodeFormat.allCases.count == 5)
    }

    @Test("LoyaltyCard.format reads the raw barcodeFormat string")
    func formatGet() {
        let c = LoyaltyCard(userId: "u1", brand: "B", number: "12345",
                            barcodeFormat: "qr", color1: "#000000", color2: "#FFFFFF")
        #expect(c.format == .qr)
        let bad = LoyaltyCard(userId: "u1", brand: "B", number: "1",
                              barcodeFormat: "nope", color1: "#000000", color2: "#FFFFFF")
        #expect(bad.format == nil)
        let none = LoyaltyCard(userId: "u1", brand: "B", number: "1",
                               color1: "#000000", color2: "#FFFFFF")
        #expect(none.format == nil)
    }

    @Test("LoyaltyCard.format writes through to the raw barcodeFormat string")
    func formatSet() {
        let c = LoyaltyCard(userId: "u1", brand: "B", number: "1",
                            color1: "#000000", color2: "#FFFFFF")
        c.format = .ean13
        #expect(c.barcodeFormat == "ean13")
        c.format = nil
        #expect(c.barcodeFormat == nil)
    }
}
