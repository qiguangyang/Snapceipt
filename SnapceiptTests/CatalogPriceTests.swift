import Testing
@testable import Snapceipt

@Suite struct CatalogPriceTests {
    @Test func inclusivePriceConversion() throws {
        #expect(try CatalogPrice.enteredCents(exclusiveCents: 10000, gstEnabled: true, gstInclusive: true, rateBp: 1000) == 11000)
        #expect(try CatalogPrice.enteredCents(exclusiveCents: 5, gstEnabled: true, gstInclusive: true, rateBp: 1000) == 6)
        #expect(try CatalogPrice.enteredCents(exclusiveCents: 10000, gstEnabled: false, gstInclusive: true, rateBp: 1000) == 10000)
        #expect(try CatalogPrice.enteredCents(exclusiveCents: 10000, gstEnabled: true, gstInclusive: false, rateBp: 1000) == 10000)
    }
    @Test func invalidPricesAndOverflowRejected() throws {
        for cents in [-1, 1_000_000_001, Int.max] {
            #expect(throws: CatalogPrice.ValidationError.self) { try CatalogPrice.enteredCents(exclusiveCents: cents, gstEnabled: true, gstInclusive: true, rateBp: 1000) }
        }
        for rate in [-1, 10001, Int.max] {
            #expect(throws: CatalogPrice.ValidationError.self) { try CatalogPrice.enteredCents(exclusiveCents: 1, gstEnabled: true, gstInclusive: true, rateBp: rate) }
        }
    }
}
