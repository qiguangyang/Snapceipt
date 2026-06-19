import Testing
@testable import Snapceipt

@Suite("LinePriceField dollar↔cents parsing")
struct LinePriceFieldTests {
    @Test("display: cents → editable dollar string ('' at zero)")
    func display() {
        #expect(LinePriceField.display(0) == "")
        #expect(LinePriceField.display(1200) == "12")
        #expect(LinePriceField.display(1250) == "12.50")
        #expect(LinePriceField.display(5) == "0.05")
    }

    @Test("cents: dollars.cents string → cents")
    func cents() {
        #expect(LinePriceField.cents(from: "") == 0)
        #expect(LinePriceField.cents(from: "12") == 1200)
        #expect(LinePriceField.cents(from: "12.5") == 1250)
        #expect(LinePriceField.cents(from: "12.50") == 1250)
        #expect(LinePriceField.cents(from: "0.99") == 99)
        #expect(LinePriceField.cents(from: "12,50") == 1250)   // comma decimal
        #expect(LinePriceField.cents(from: "$8.40") == 840)    // stray characters
        #expect(LinePriceField.cents(from: "12.") == 1200)     // mid-typing
    }
}
