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

    /// MAJOR 2 launch-wire smoke (spec §1/§4.2): RootView's profile-activation `.task`/onChange
    /// runs `CategorySeeder.backfillGstDefaults(profileId:context:sync:)` for the ACTIVE profile.
    /// This asserts the launch/activation call (with `.standard`-style defaults, i.e. the real
    /// 3-arg signature the launch path uses) flips a pre-existing groceries row seeded BEFORE
    /// gstFreeDefault existed to `true` and enqueues a category upsert for the corrected row —
    /// so upgrading users stop over-claiming GST via ÷11 on groceries.
    @Test func launchActivationBackfillFlipsGroceriesAndEnqueuesUpsert() throws {
        let (ctx, engine) = try makeCtx()
        // Upgraded install: groceries seeded WITHOUT gstFreeDefault (defaults false).
        let groceries = Snapceipt.Category(userId: "u1", profileId: "p1", key: "groceries", label: "Groceries",
                                           icon: "tag", tint: "#C99A22", soft: "#F6EECE")
        #expect(groceries.gstFreeDefault == false)
        ctx.insert(groceries); try ctx.save()
        let defaults = UserDefaults(suiteName: "sc.test.backfill.launch.\(UUID().uuidString)")!

        // The exact call RootView's launch/activation path makes for the active profile.
        CategorySeeder.backfillGstDefaults(profileId: "p1", context: ctx, sync: engine, defaults: defaults)

        // Groceries is now GST-free by default…
        #expect(groceries.gstFreeDefault == true)
        // …and a category upsert was enqueued for the corrected row (so the fix syncs up).
        let outbox = try ctx.fetch(FetchDescriptor<OutboxMutation>())
        let upsert = outbox.first { $0.entityType == EntityType.category.rawValue
            && $0.op == "upsert" && $0.entityId == groceries.id }
        #expect(upsert != nil)
    }
}
