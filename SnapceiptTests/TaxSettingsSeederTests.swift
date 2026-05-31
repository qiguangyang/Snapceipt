import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("TaxSettingsSeeder")
struct TaxSettingsSeederTests {

    private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let context = ModelContext(container)
        return (context, MockSyncEngine())
    }

    @Test("ensure() creates one TaxSettings with ATO defaults + enqueues an upsert")
    func ensureCreates() throws {
        let (ctx, sync) = try makeFixture()
        TaxSettingsSeeder.ensure(profileId: "p1", userId: "u1", context: ctx, sync: sync)

        let rows = try ctx.fetch(FetchDescriptor<TaxSettings>())
        #expect(rows.count == 1)
        let s = rows[0]
        #expect(s.profileId == "p1")
        #expect(s.userId == "u1")
        #expect(s.wfhRateCentsPerHour == 70)
        #expect(s.mileageRateCentsPerKm == 88)
        #expect(s.financialYearStartMonth == 7)
        #expect(s.gstRateBps == 1000)
        #expect(s.mealsDeductiblePct == 50)
        #expect(sync.calls.count == 1)
        #expect(sync.calls.first?.op == "upsert")
        #expect(sync.calls.first?.entityType == .taxSettings)
    }

    @Test("ensure() is idempotent for the same profile (legacy already-seeded)")
    func ensureIdempotent() throws {
        let (ctx, sync) = try makeFixture()
        TaxSettingsSeeder.ensure(profileId: "p1", userId: "u1", context: ctx, sync: sync)
        TaxSettingsSeeder.ensure(profileId: "p1", userId: "u1", context: ctx, sync: sync)

        let rows = try ctx.fetch(FetchDescriptor<TaxSettings>())
        #expect(rows.count == 1)            // not duplicated
        #expect(sync.calls.count == 1)      // second call enqueues nothing
    }

    @Test("ensure() ignores a soft-deleted row and re-seeds")
    func ensureSkipsDeleted() throws {
        let (ctx, sync) = try makeFixture()
        let dead = TaxSettings(userId: "u1", profileId: "p1", deletedAt: 123)
        ctx.insert(dead)
        try ctx.save()

        TaxSettingsSeeder.ensure(profileId: "p1", userId: "u1", context: ctx, sync: sync)
        let live = try ctx.fetch(FetchDescriptor<TaxSettings>(
            predicate: #Predicate { $0.profileId == "p1" && $0.deletedAt == nil }))
        #expect(live.count == 1)
        #expect(sync.calls.count == 1)
    }
}
