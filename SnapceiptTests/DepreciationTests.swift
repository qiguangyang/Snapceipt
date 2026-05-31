import Testing
import Foundation
@testable import Snapceipt

@Suite("Depreciation")
struct DepreciationTests {

    @Test("car cost limit caps the base value at $69,674")
    func costLimit() {
        #expect(Depreciation.cappedCostCents(80_000_00) == 69_674_00)
        #expect(Depreciation.cappedCostCents(40_000_00) == 40_000_00)
    }

    @Test("full-year diminishing value = cost * 25% (8yr life)")
    func dvFullYear() {
        // 40,000 * 2/8 = 10,000 over a full year (365 days held)
        let cents = Depreciation.declineCents(
            costCents: 40_000_00, method: .diminishingValue, effectiveLifeYears: 8, daysHeld: 365)
        #expect(cents == 10_000_00)
    }

    @Test("full-year prime cost = cost * 12.5% (8yr life)")
    func pcFullYear() {
        let cents = Depreciation.declineCents(
            costCents: 40_000_00, method: .primeCost, effectiveLifeYears: 8, daysHeld: 365)
        #expect(cents == 5_000_00)
    }

    @Test("part-year prorates by daysHeld/365")
    func partYear() {
        // half a year held (182 days) on DV: 10,000 * 182/365 = 4,986.30 -> 498630 cents
        let cents = Depreciation.declineCents(
            costCents: 40_000_00, method: .diminishingValue, effectiveLifeYears: 8, daysHeld: 182)
        #expect(cents == 498_630)
    }

    @Test("cost above the limit depreciates off the capped base")
    func cappedDV() {
        // capped 69,674 * 25% full year = 17,418.50 -> 1741850 cents
        let cents = Depreciation.declineCents(
            costCents: 100_000_00, method: .diminishingValue, effectiveLifeYears: 8, daysHeld: 365)
        #expect(cents == 1_741_850)
    }
}
