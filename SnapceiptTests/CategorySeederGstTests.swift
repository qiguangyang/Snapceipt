import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor
@Suite(.serialized)
struct CategorySeederGstTests {
    private func makeCtx() throws -> (ModelContext, SyncEngine) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let engine = SyncEngine(api: MockAPIClient(), context: ctx, auth: AuthStore(), toast: ToastCenter())
        return (ctx, engine)
    }

    @Test func seedSetsGroceriesGstFreeAndRestTaxable() throws {
        let (ctx, engine) = try makeCtx()
        CategorySeeder.ensure(profileId: "p1", userId: "u1", context: ctx, sync: engine)
        let cats = try ctx.fetch(FetchDescriptor<Snapceipt.Category>())
        let byKey = Dictionary(uniqueKeysWithValues: cats.map { ($0.key, $0.gstFreeDefault) })
        #expect(byKey["groceries"] == true)
        #expect(byKey["meals"] == false)
        #expect(byKey["health"] == false)
        #expect(byKey["fuel"] == false)
        #expect(byKey["income"] == false)
    }

    @Test func backfillFlipsExistingGroceriesOnlyAndRunsOnce() throws {
        let (ctx, engine) = try makeCtx()
        // Simulate a pre-feature install: rows inserted WITHOUT gstFreeDefault (all false).
        let groceries = Snapceipt.Category(userId: "u1", profileId: "p1", key: "groceries", label: "Groceries",
                                 icon: "tag", tint: "#C99A22", soft: "#F6EECE")
        let meals = Snapceipt.Category(userId: "u1", profileId: "p1", key: "meals", label: "Meals",
                             icon: "tag", tint: "#E8602C", soft: "#FBEADF")
        ctx.insert(groceries); ctx.insert(meals); try ctx.save()
        let defaults = UserDefaults(suiteName: "sc.test.backfill.\(UUID().uuidString)")!

        CategorySeeder.backfillGstDefaults(profileId: "p1", context: ctx, sync: engine, defaults: defaults)
        #expect(groceries.gstFreeDefault == true)
        #expect(meals.gstFreeDefault == false)

        // Idempotent: a second run does not re-enqueue (outbox count stable after a fresh read).
        let outboxAfterFirst = try ctx.fetch(FetchDescriptor<OutboxMutation>()).count
        CategorySeeder.backfillGstDefaults(profileId: "p1", context: ctx, sync: engine, defaults: defaults)
        let outboxAfterSecond = try ctx.fetch(FetchDescriptor<OutboxMutation>()).count
        #expect(outboxAfterSecond == outboxAfterFirst)
    }
}
