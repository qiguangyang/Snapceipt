import Testing
import SwiftData
@testable import Snapceipt

/// The Activity tab's receipts list. The capture save path is already proven by
/// CaptureViewModelTests.saveInsertsAndEnqueues; this proves a saved receipt is then
/// fetched/displayed (the missing surface that made receipts look "lost").
@MainActor
struct ReceiptsListViewModelTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
    }

    private func insert(_ c: ModelContext, profileId: String, merchant: String,
                        date: String, cents: Int = -1000, cat: String = "meals", deletedAt: Int? = nil) {
        c.insert(Transaction(userId: "u1", profileId: profileId, merchant: merchant,
                             catKey: cat, amountCents: cents, txnDate: date,
                             source: "scan", deletedAt: deletedAt))
    }

    @Test("lists the active profile's receipts newest-first, excluding deleted + other profiles")
    func scopedAndSorted() throws {
        let c = try makeContext()
        insert(c, profileId: "p1", merchant: "Cafe", date: "2026-05-01")
        insert(c, profileId: "p1", merchant: "Fuel", date: "2026-06-01", cat: "fuel")
        insert(c, profileId: "p1", merchant: "Deleted", date: "2026-06-05", deletedAt: 123)
        insert(c, profileId: "p2", merchant: "OtherProfile", date: "2026-06-10")
        try c.save()

        let vm = ReceiptsListViewModel(context: c, profileId: "p1")
        #expect(vm.rows.map(\.merchant) == ["Fuel", "Cafe"])
    }

    @Test("an empty profile id yields no rows (no active profile)")
    func emptyProfileId() throws {
        let vm = ReceiptsListViewModel(context: try makeContext(), profileId: "")
        #expect(vm.rows.isEmpty)
    }

    @Test("row maps merchant fallback, category, and expense sign for display")
    func rowMapping() throws {
        let c = try makeContext()
        insert(c, profileId: "p1", merchant: "", date: "2026-05-28", cents: -1099, cat: "meals")
        try c.save()

        let row = try #require(ReceiptsListViewModel(context: c, profileId: "p1").rows.first)
        #expect(row.merchant == "Receipt")        // empty merchant → fallback
        #expect(row.category == .meals)
        #expect(row.isIncome == false)            // negative cents = expense
        #expect(!row.amountText.isEmpty)
        #expect(row.dateText.contains("2026"))    // locale-robust
    }
}
