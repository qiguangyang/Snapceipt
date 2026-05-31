import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("WFHViewModel")
struct WFHViewModelTests {

    private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(container), MockSyncEngine())
    }

    @Test("logHours inserts a new log with snapshotted rate + claim and enqueues it")
    func logHoursInsert() throws {
        let (ctx, sync) = try makeFixture()
        let vm = WFHViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1",
                              rateCentsPerHour: 70, startMonth: 7)
        vm.logHours(date: "2025-09-03", minutes: 90, note: "Invoices")

        let rows = try ctx.fetch(FetchDescriptor<WFHLog>())
        #expect(rows.count == 1)
        let log = rows[0]
        #expect(log.logDate == "2025-09-03")
        #expect(log.minutes == 90)
        #expect(log.note == "Invoices")
        #expect(log.rateCentsPerHour == 70)
        #expect(log.claimCents == 105)        // 1.5h * 70
        #expect(log.profileId == "p1")
        #expect(sync.calls.count == 1)
        #expect(sync.calls[0].entityType == .wfhLog)
        #expect(sync.calls[0].op == "upsert")
    }

    @Test("logHours on an existing date edits in place (one-per-day)")
    func logHoursEditsInPlace() throws {
        let (ctx, sync) = try makeFixture()
        let vm = WFHViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1",
                              rateCentsPerHour: 70, startMonth: 7)
        vm.logHours(date: "2025-09-03", minutes: 90, note: "First")
        vm.logHours(date: "2025-09-03", minutes: 120, note: "Updated")

        let rows = try ctx.fetch(FetchDescriptor<WFHLog>(
            predicate: #Predicate { $0.deletedAt == nil }))
        #expect(rows.count == 1)              // not duplicated
        #expect(rows[0].minutes == 120)
        #expect(rows[0].note == "Updated")
        #expect(rows[0].claimCents == 140)    // 2h * 70
    }

    @Test("hero aggregates FY logs for the active profile only")
    func heroScoped() throws {
        let (ctx, sync) = try makeFixture()
        // other profile log -> must be excluded
        let other = WFHLog(userId: "u1", profileId: "p2", logDate: "2025-08-01",
                           minutes: 480, rateCentsPerHour: 70, claimCents: 560)
        ctx.insert(other)
        let vm = WFHViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1",
                              rateCentsPerHour: 70, startMonth: 7)
        vm.logHours(date: "2025-08-10", minutes: 300, note: nil)   // claim 350

        let hero = vm.hero(fyStartYear: 2025)
        #expect(hero.daysLogged == 1)
        #expect(hero.totalMinutes == 300)
        #expect(hero.claimCents == 350)
    }

    @Test("existingLog(for:) returns a row to pre-fill the sheet")
    func existingLog() throws {
        let (ctx, sync) = try makeFixture()
        let vm = WFHViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1",
                              rateCentsPerHour: 70, startMonth: 7)
        vm.logHours(date: "2025-09-03", minutes: 90, note: "Note")
        let found = vm.existingLog(for: "2025-09-03")
        #expect(found?.minutes == 90)
        #expect(vm.existingLog(for: "2025-01-01") == nil)
    }
}
