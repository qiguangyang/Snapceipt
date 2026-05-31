import Testing
import Foundation
@testable import Snapceipt

@Suite("MileageCalc")
struct MileageCalcTests {

    @Test("distance is end - start metres; nil/invalid -> nil")
    func odometerDistance() {
        #expect(MileageCalc.distanceM(startM: 10_000_000, endM: 10_012_400) == 12_400)
        #expect(MileageCalc.distanceM(startM: nil, endM: 10_012_400) == nil)
        #expect(MileageCalc.distanceM(startM: 10_012_400, endM: 10_000_000) == nil)  // end <= start
    }

    @Test("end-greater-than-start validation")
    func endGreaterThanStart() {
        #expect(MileageCalc.isValidOdometer(startM: 1000, endM: 2000) == true)
        #expect(MileageCalc.isValidOdometer(startM: 2000, endM: 2000) == false)
        #expect(MileageCalc.isValidOdometer(startM: 2000, endM: 1000) == false)
    }

    @Test("business-use % = round(business km / total km * 100) over in-window trips")
    func businessUsePct() {
        // window 2025-08-12 .. 2025-11-04
        let trips = [
            MileageCalc.Trip(tripDate: "2025-08-20", distanceM: 30_000, isBusiness: true),   // in
            MileageCalc.Trip(tripDate: "2025-09-01", distanceM: 10_000, isBusiness: false),  // in
            MileageCalc.Trip(tripDate: "2025-12-01", distanceM: 99_000, isBusiness: true),   // OUT of window
        ]
        // business 30km / total 40km = 75%
        let pct = MileageCalc.businessUsePct(trips: trips, start: "2025-08-12", end: "2025-11-04")
        #expect(pct == 75)
    }

    @Test("business-use % is nil with no in-window trips")
    func businessUsePctNilWhenNoTrips() {
        let pct = MileageCalc.businessUsePct(trips: [], start: "2025-08-12", end: "2025-11-04")
        #expect(pct == nil)
    }

    @Test("vehicle-year claim = round(pct/100 * sum(costs))")
    func vehicleYearClaim() {
        let costs = MileageCalc.Costs(fuelCents: 200_000, regoCents: 80_000, insuranceCents: 90_000,
                                      servicingCents: 40_000, otherCents: 2_000, depreciationCents: 0)
        #expect(costs.totalCents == 412_000)
        #expect(MileageCalc.claimCents(businessUsePct: 78, costs: costs) == 321_360) // 0.78 * 412000
        #expect(MileageCalc.claimCents(businessUsePct: 0, costs: costs) == 0)
    }

    @Test("FY hero sums business-trip km + counts trips in the FY")
    func fyHero() {
        let trips = [
            MileageCalc.Trip(tripDate: "2025-07-10", distanceM: 12_400, isBusiness: true),  // in FY, biz
            MileageCalc.Trip(tripDate: "2025-09-01", distanceM: 8_000, isBusiness: false),  // in FY, personal
            MileageCalc.Trip(tripDate: "2025-06-30", distanceM: 50_000, isBusiness: true),  // prev FY
        ]
        let hero = MileageCalc.hero(trips: trips, fyStartYear: 2025, startMonth: 7)
        #expect(hero.businessKm == 12.4)
        #expect(hero.tripCount == 2)   // both FY25-26 trips counted
    }
}
