import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("MileageViewModel")
struct MileageViewModelTests {

    private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(container), MockSyncEngine())
    }

    private func makeVM(_ ctx: ModelContext, _ sync: MockSyncEngine) -> MileageViewModel {
        MileageViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1", startMonth: 7)
    }

    @Test("saveVehicle inserts a Vehicle + enqueues it")
    func saveVehicle() throws {
        let (ctx, sync) = try makeFixture()
        let vm = makeVM(ctx, sync)
        vm.saveVehicle(make: "Toyota", model: "HiLux", engineCc: 2800, registration: "ABC123")

        let rows = try ctx.fetch(FetchDescriptor<Vehicle>())
        #expect(rows.count == 1)
        #expect(rows[0].make == "Toyota")
        #expect(vm.vehicle?.id == rows[0].id)
        #expect(sync.calls.contains { $0.entityType == .vehicle && $0.op == "upsert" })
    }

    @Test("addTrip derives distance from odometer + recomputes business-use %")
    func addTripRecomputesPct() throws {
        let (ctx, sync) = try makeFixture()
        let vm = makeVM(ctx, sync)
        vm.saveVehicle(make: "Toyota", model: "HiLux", engineCc: nil, registration: nil)
        vm.startLogbook(startDate: "2025-08-12")  // 12-week end auto-derived

        // 30km business + 10km personal, both inside the window -> 75%
        vm.addTrip(date: "2025-08-20", odometerStartM: 0, odometerEndM: 30_000,
                   isBusiness: true, purpose: "Client", fromLabel: nil, toLabel: nil)
        vm.addTrip(date: "2025-09-01", odometerStartM: 30_000, odometerEndM: 40_000,
                   isBusiness: false, purpose: "Personal", fromLabel: nil, toLabel: nil)

        #expect(vm.vehicle?.businessUsePct == 75)
        let trips = try ctx.fetch(FetchDescriptor<MileageTrip>())
        #expect(trips.count == 2)
        #expect(trips.contains { $0.distanceM == 30_000 })
        #expect(sync.calls.contains { $0.entityType == .mileageTrip })
        // recompute persists the vehicle again:
        #expect(sync.calls.filter { $0.entityType == .vehicle }.count >= 2)
    }

    @Test("saveCosts recomputes the current-FY VehicleYear claim from the cached %")
    func saveCostsComputesClaim() throws {
        let (ctx, sync) = try makeFixture()
        let vm = makeVM(ctx, sync)
        vm.saveVehicle(make: "Toyota", model: "HiLux", engineCc: nil, registration: nil)
        vm.startLogbook(startDate: "2025-08-12")
        vm.addTrip(date: "2025-08-20", odometerStartM: 0, odometerEndM: 78_000,
                   isBusiness: true, purpose: "Client", fromLabel: nil, toLabel: nil)
        vm.addTrip(date: "2025-08-21", odometerStartM: 78_000, odometerEndM: 100_000,
                   isBusiness: false, purpose: "Personal", fromLabel: nil, toLabel: nil)
        #expect(vm.vehicle?.businessUsePct == 78)  // 78000/100000

        vm.saveCosts(fyStartYear: 2025, fuelCents: 200_000, regoCents: 80_000,
                     insuranceCents: 90_000, servicingCents: 40_000, otherCents: 2_000,
                     depreciationCents: 0)

        let years = try ctx.fetch(FetchDescriptor<VehicleYear>())
        #expect(years.count == 1)
        #expect(years[0].businessUsePct == 78)
        #expect(years[0].claimCents == 321_360)   // 0.78 * 412000
        #expect(sync.calls.contains { $0.entityType == .vehicleYear })
    }

    @Test("hero is empty + claim nil with no vehicle/trips")
    func emptyHero() throws {
        let (ctx, sync) = try makeFixture()
        let vm = makeVM(ctx, sync)
        let hero = vm.hero(fyStartYear: 2025)
        #expect(hero.businessKm == 0)
        #expect(hero.tripCount == 0)
        #expect(vm.vehicle == nil)
        #expect(vm.currentClaimCents(fyStartYear: 2025) == nil)
    }
}
