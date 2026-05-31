import Testing
@testable import Snapceipt

@Suite("EntityType")
struct EntityTypeTests {
    @Test("has exactly the 14 syncable cases")
    func count() {
        #expect(EntityType.allCases.count == 14)
    }

    @Test("raw values match the backend camelCase contract")
    func rawValues() {
        let expected = [
            "transaction", "lineItem", "profile", "category", "smartRule",
            "budget", "loyaltyCard", "quote", "quoteLineItem",
            "mileageTrip", "wfhLog", "taxSettings", "vehicle", "vehicleYear",
        ]
        #expect(EntityType.allCases.map(\.rawValue) == expected)
    }

    @Test("round-trips through its raw string")
    func roundTrip() throws {
        let t = try #require(EntityType(rawValue: "loyaltyCard"))
        #expect(t == .loyaltyCard)
        #expect(EntityType(rawValue: "nope") == nil)
    }
}
