import Testing
import Foundation
import SwiftData
@testable import Snapceipt

/// The manual-entry line-item reconcile: insert new rows, update kept rows,
/// soft-delete removed rows, enqueue each — mirrors `QuoteEditorViewModelTests`'
/// diff coverage (in-memory `ModelContext` + `MockSyncEngine`).
@MainActor
@Suite("ManualItemsReconciler")
struct ManualItemsReconcilerTests {

    private func fixture() throws -> (ModelContext, MockSyncEngine) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(container), MockSyncEngine())
    }

    private func liveItems(_ ctx: ModelContext, txnId: String) throws -> [LineItem] {
        try ctx.fetch(FetchDescriptor<LineItem>(
            predicate: #Predicate { $0.transactionId == txnId && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder)]))
    }

    @Test("create: inserts each named row, drops blanks, enqueues one upsert per item")
    func createInserts() throws {
        let (ctx, sync) = try fixture()
        let drafts = [ItemDraft(id: "A", name: "Coffee", priceText: "4.50"),
                      ItemDraft(id: "B", name: "Tea",    priceText: "3.00"),
                      ItemDraft(id: "Z", name: "",       priceText: "")]   // blank -> dropped
        let kept = ManualItemsReconciler.reconcile(
            drafts: drafts, originalIds: [], txnId: "t1", userId: "u9", context: ctx, sync: sync)

        let live = try liveItems(ctx, txnId: "t1")
        #expect(live.count == 2)
        #expect(live.map(\.name) == ["Coffee", "Tea"])
        #expect(live[0].priceCents == 450)
        #expect(live.allSatisfy { $0.userId == "u9" && $0.transactionId == "t1" })
        #expect(kept == ["A", "B"])
        #expect(sync.calls.filter { $0.entityType == .lineItem && $0.op == "upsert" }.count == 2)
        #expect(sync.calls.contains { $0.entityType == .lineItem && $0.op == "delete" } == false)
    }

    @Test("edit: updates a kept row, inserts a new one, soft-deletes a removed one + enqueues its delete")
    func editReconciles() throws {
        let (ctx, sync) = try fixture()
        // First save: A + B.
        let first = ManualItemsReconciler.reconcile(
            drafts: [ItemDraft(id: "A", name: "Coffee", priceText: "4.50"),
                     ItemDraft(id: "B", name: "Tea",    priceText: "3.00")],
            originalIds: [], txnId: "t1", userId: "u9", context: ctx, sync: sync)
        #expect(first == ["A", "B"])

        // Reopen: A re-priced, C added, B removed.
        let kept = ManualItemsReconciler.reconcile(
            drafts: [ItemDraft(id: "A", name: "Coffee", priceText: "5.00"),
                     ItemDraft(id: "C", name: "Cake",   priceText: "6.00")],
            originalIds: first, txnId: "t1", userId: "u9", context: ctx, sync: sync)

        let live = try liveItems(ctx, txnId: "t1")
        #expect(live.count == 2)
        #expect(Set(live.map(\.name)) == ["Coffee", "Cake"])
        let a = live.first { $0.id == "A" }
        #expect(a?.priceCents == 500)                 // updated in place
        #expect(live.first { $0.id == "C" } != nil)   // inserted

        // B is soft-deleted, not gone.
        let b = try ctx.fetch(FetchDescriptor<LineItem>(predicate: #Predicate { $0.id == "B" })).first
        #expect(b != nil)
        #expect(b?.deletedAt != nil)

        #expect(kept == ["A", "C"])
        #expect(sync.calls.contains { $0.entityType == .lineItem && $0.op == "delete" })
    }

    @Test("removing every row soft-deletes them all and keeps nothing")
    func removeAll() throws {
        let (ctx, sync) = try fixture()
        let first = ManualItemsReconciler.reconcile(
            drafts: [ItemDraft(id: "A", name: "Coffee", priceText: "4.50")],
            originalIds: [], txnId: "t1", userId: "u9", context: ctx, sync: sync)
        let kept = ManualItemsReconciler.reconcile(
            drafts: [], originalIds: first, txnId: "t1", userId: "u9", context: ctx, sync: sync)
        #expect(kept.isEmpty)
        #expect(try liveItems(ctx, txnId: "t1").isEmpty)
        #expect(sync.calls.contains { $0.entityType == .lineItem && $0.op == "delete" })
    }
}
