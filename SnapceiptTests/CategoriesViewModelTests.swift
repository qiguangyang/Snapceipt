import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("CategoriesViewModel")
struct CategoriesViewModelTests {
    private func fixture() throws -> (ModelContext, MockSyncEngine) {
        let c = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(c), MockSyncEngine())
    }

    @Test("seeds built-in categories once and lists them")
    func seeds() throws {
        let (ctx, sync) = try fixture()
        let vm = CategoriesViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
        let firstCount = vm.categories.count
        #expect(firstCount >= 9) // the built-in taxonomy (custom excluded)
        // re-init: idempotent, no duplicates
        let vm2 = CategoriesViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
        #expect(vm2.categories.count == firstCount)
    }

    @Test("editing a category default deductible % persists + enqueues")
    func editDefault() throws {
        let (ctx, sync) = try fixture()
        let vm = CategoriesViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
        let cat = vm.categories.first!
        sync.calls.removeAll()
        vm.setDefaultDeductible(cat, pct: 25)
        #expect(cat.defaultDeductiblePct == 25)
        #expect(sync.calls.last?.entityType == .category)
        #expect(sync.calls.last?.op == "upsert")
    }

    @Test("receiptCount reflects email_in/manual transactions for the profile by catKey")
    func counts() throws {
        let (ctx, sync) = try fixture()
        ctx.insert(Transaction(userId: "u1", profileId: "p1", catKey: "office", amountCents: -100, txnDate: "2026-06-01"))
        ctx.insert(Transaction(userId: "u1", profileId: "p1", catKey: "office", amountCents: -200, txnDate: "2026-06-02"))
        try ctx.save()
        let vm = CategoriesViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
        let office = vm.categories.first { $0.key == "office" }!
        #expect(vm.receiptCount(office) == 2)
    }
}
