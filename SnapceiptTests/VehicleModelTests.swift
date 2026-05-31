import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@Suite("VehicleModel")
struct VehicleModelTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return ModelContext(container)
    }

    @Test("Vehicle round-trips with all logbook fields + sync envelope")
    func vehicleRoundTrip() throws {
        let ctx = try makeContext()
        let v = Vehicle(
            userId: "u1", profileId: "p1",
            make: "Toyota", model: "HiLux", engineCc: 2800, registration: "ABC123",
            logbookStartDate: "2025-08-12", logbookEndDate: "2025-11-04",
            businessUsePct: 78, rev: 2, lastEditedDeviceId: "dev-1"
        )
        ctx.insert(v)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Vehicle>())
        let got = try #require(rows.first)
        #expect(got.make == "Toyota")
        #expect(got.model == "HiLux")
        #expect(got.engineCc == 2800)
        #expect(got.registration == "ABC123")
        #expect(got.logbookStartDate == "2025-08-12")
        #expect(got.logbookEndDate == "2025-11-04")
        #expect(got.businessUsePct == 78)
        #expect(got.userId == "u1")
        #expect(got.profileId == "p1")
        #expect(got.rev == 2)
        #expect(got.lastEditedDeviceId == "dev-1")
        #expect(got.entityType == .vehicle)
    }

    @Test("VehicleYear round-trips with all cost fields + claim cache")
    func vehicleYearRoundTrip() throws {
        let ctx = try makeContext()
        let vy = VehicleYear(
            userId: "u1", profileId: "p1", vehicleId: "veh-1", fyStartYear: 2025,
            odometerOpenM: 10_000_000, odometerCloseM: 25_000_000,
            fuelCents: 200_000, regoCents: 80_000, insuranceCents: 90_000,
            servicingCents: 40_000, otherCents: 2_000, depreciationCents: 0,
            businessUsePct: 78, claimCents: 321_360
        )
        ctx.insert(vy)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<VehicleYear>())
        let got = try #require(rows.first)
        #expect(got.vehicleId == "veh-1")
        #expect(got.fyStartYear == 2025)
        #expect(got.fuelCents == 200_000)
        #expect(got.regoCents == 80_000)
        #expect(got.insuranceCents == 90_000)
        #expect(got.servicingCents == 40_000)
        #expect(got.otherCents == 2_000)
        #expect(got.depreciationCents == 0)
        #expect(got.businessUsePct == 78)
        #expect(got.claimCents == 321_360)
        #expect(got.entityType == .vehicleYear)
    }

    @Test("MileageTrip carries vehicleId + odometer columns and stays profile-scoped")
    func mileageTripExtended() throws {
        let ctx = try makeContext()
        let pid = "p1"
        let t = MileageTrip(
            userId: "u1", profileId: pid, tripDate: "2025-09-01",
            distanceM: 12_400, isBusiness: true,
            vehicleId: "veh-1", odometerStartM: 10_000_000, odometerEndM: 10_012_400
        )
        ctx.insert(t)
        try ctx.save()

        let rows = try ctx.fetch(
            FetchDescriptor<MileageTrip>(predicate: #Predicate { $0.profileId == pid }))
        let got = try #require(rows.first)
        #expect(got.vehicleId == "veh-1")
        #expect(got.odometerStartM == 10_000_000)
        #expect(got.odometerEndM == 10_012_400)
        #expect(got.distanceM == 12_400)
        #expect(got.entityType == .mileageTrip)
    }

    @Test("TaxSettings WFH default is now 70 cents/hour")
    func wfhDefault70() {
        let s = TaxSettings(userId: "u1", profileId: "p1")
        #expect(s.wfhRateCentsPerHour == 70)
        #expect(s.mileageRateCentsPerKm == 88)
        #expect(s.financialYearStartMonth == 7)
        #expect(s.gstRateBps == 1000)
        #expect(s.mealsDeductiblePct == 50)
    }
}
