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

    // MARK: - Task 2: CoreImage generators

    @Test("each CoreImage format renders a non-nil image for a valid value")
    func coreImageNonNil() {
        for f: LoyaltyCard.BarcodeFormat in [.code128, .qr, .pdf417, .aztec] {
            let img = BarcodeRenderer.image(value: "ABC123456", format: f, scale: 4)
            #expect(img != nil, "expected an image for \(f.rawValue)")
            if let img { #expect(img.size.width > 0 && img.size.height > 0) }
        }
    }

    @Test("CoreImage formats return nil for an empty value")
    func coreImageEmptyNil() {
        for f: LoyaltyCard.BarcodeFormat in [.code128, .qr, .pdf417, .aztec] {
            #expect(BarcodeRenderer.image(value: "", format: f, scale: 4) == nil,
                    "expected nil for empty \(f.rawValue)")
        }
    }

    // MARK: - Task 3: EAN-13 / UPC-A

    @Test("mod-10 check digit for a known EAN-13 (5901234123457 -> 7)")
    func ean13CheckDigit() {
        #expect(BarcodeRenderer.ean13CheckDigit("590123412345") == 7)
    }

    @Test("EAN-13 module string is 95 wide with guards and centre guard")
    func ean13ModuleString() {
        let mods = BarcodeRenderer.ean13Modules("5901234123457")
        #expect(mods != nil)
        guard let mods else { return }
        #expect(mods.count == 95)
        #expect(mods.hasPrefix("101"))   // left guard
        #expect(mods.hasSuffix("101"))   // right guard
        let centre = String(Array(mods)[45..<50])
        #expect(centre == "01010")
    }

    @Test("EAN-13 renders a non-nil image for a valid 13-digit value")
    func ean13ValidImage() {
        #expect(BarcodeRenderer.image(value: "5901234123457", format: .ean13, scale: 3) != nil)
    }

    @Test("UPC-A (12 digits) renders as EAN-13 with a leading zero")
    func upcAImage() {
        #expect(BarcodeRenderer.image(value: "036000291452", format: .ean13, scale: 3) != nil)
    }

    @Test("EAN-13 rejects wrong length, non-digit, and bad checksum -> nil")
    func ean13Invalid() {
        #expect(BarcodeRenderer.image(value: "123", format: .ean13, scale: 3) == nil)
        #expect(BarcodeRenderer.image(value: "59012341234A7", format: .ean13, scale: 3) == nil)
        #expect(BarcodeRenderer.image(value: "5901234123458", format: .ean13, scale: 3) == nil) // bad checksum
    }
}
