import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("BudgetListViewModel")
struct BudgetListViewModelTests {
    private func iso(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(container), MockSyncEngine())
    }

    private func vm(_ ctx: ModelContext, _ sync: MockSyncEngine) -> BudgetListViewModel {
        BudgetListViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1",
                            now: iso("2026-06-15"))
    }

    @Test("create inserts a budget scoped to the active profile and enqueues upsert")
    func createEnqueues() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        v.save(existing: nil, categoryId: nil, catKey: nil, label: "Everything",
               capCents: 600_00, alertThresholdPct: 90)
        let rows = try ctx.fetch(FetchDescriptor<Budget>(predicate: #Predicate { $0.deletedAt == nil }))
        #expect(rows.count == 1)
        #expect(rows[0].profileId == "p1")
        #expect(rows[0].capCents == 600_00)
        #expect(rows[0].alertThresholdPct == 90)
        #expect(rows[0].period == "monthly")
        #expect(sync.calls.count == 1)
        #expect(sync.calls[0].entityType == .budget)
        #expect(sync.calls[0].op == "upsert")
    }

    @Test("save with an existing budget updates in place (no duplicate)")
    func updateInPlace() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        v.save(existing: nil, categoryId: nil, catKey: nil, label: "Cap", capCents: 100_00, alertThresholdPct: 90)
        let row = v.budgets[0]
        v.save(existing: row, categoryId: nil, catKey: nil, label: "Cap", capCents: 250_00, alertThresholdPct: 80)
        let live = try ctx.fetch(FetchDescriptor<Budget>(predicate: #Predicate { $0.deletedAt == nil }))
        #expect(live.count == 1)
        #expect(live[0].capCents == 250_00)
        #expect(live[0].alertThresholdPct == 80)
        #expect(sync.calls.count == 2)
    }

    @Test("delete soft-deletes and enqueues a delete")
    func deleteSoft() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        v.save(existing: nil, categoryId: nil, catKey: nil, label: "Cap", capCents: 100_00, alertThresholdPct: 90)
        let row = v.budgets[0]
        v.delete(row)
        let live = try ctx.fetch(FetchDescriptor<Budget>(predicate: #Predicate { $0.deletedAt == nil }))
        #expect(live.isEmpty)
        #expect(sync.calls.last?.op == "delete")
        #expect(v.budgets.isEmpty)
    }

    @Test("rows expose spent + over-cap; top3 returns at most 3 by cap desc")
    func rowsAndTop3() throws {
        let (ctx, sync) = try makeFixture()
        ctx.insert(Transaction(userId: "u1", profileId: "p1", catKey: "meals",
                               amountCents: -200_00, txnDate: "2026-06-03"))
        try? ctx.save()
        let v = vm(ctx, sync)
        v.save(existing: nil, categoryId: nil, catKey: nil, label: "All", capCents: 100_00, alertThresholdPct: 90)
        v.save(existing: nil, categoryId: nil, catKey: nil, label: "Big", capCents: 900_00, alertThresholdPct: 90)
        v.save(existing: nil, categoryId: nil, catKey: nil, label: "Mid", capCents: 500_00, alertThresholdPct: 90)
        v.save(existing: nil, categoryId: nil, catKey: nil, label: "Low", capCents: 100_00, alertThresholdPct: 90)
        let rows = v.rows()
        let all = rows.first(where: { $0.budget.label == "All" })!
        #expect(all.spentCents == 200_00)
        #expect(all.overCap == true)
        let top = v.top3()
        #expect(top.count == 3)
        #expect(top[0].budget.capCents == 900_00)   // sorted by cap desc
    }
}
