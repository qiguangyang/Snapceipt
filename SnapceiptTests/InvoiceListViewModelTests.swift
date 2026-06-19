import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("InvoiceListViewModel")
struct InvoiceListViewModelTests {
    private func ctx() throws -> ModelContext {
        ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
    }
    /// Seed an invoice; returns it. `created` controls ordering (newest-first).
    @discardableResult
    private func seed(_ c: ModelContext, status: String, total: Int, due: String?,
                      created: Int, profile: String = "p1", payments: [Int] = []) -> Invoice {
        let inv = Invoice(userId: "u1", profileId: profile, totalCents: total,
                          status: status, dueDate: due, createdAt: created, updatedAt: created)
        c.insert(inv)
        for amt in payments { c.insert(Payment(userId: "u1", invoiceId: inv.id, amountCents: amt, paidOn: "2026-06-01")) }
        return inv
    }

    @Test("needs-attention: overdue first, then due-soon; paid/draft/far-future excluded")
    func sectioning() throws {
        let c = try ctx()
        let today = "2026-07-10"
        let overdue = seed(c, status: "issued", total: 100_00, due: "2026-07-01", created: 100)   // past due
        let dueSoon = seed(c, status: "issued", total: 100_00, due: "2026-07-14", created: 200)    // 4 days out
        let far = seed(c, status: "issued", total: 100_00, due: "2026-09-01", created: 300)        // far future
        let paid = seed(c, status: "issued", total: 100_00, due: "2026-07-01", created: 400, payments: [100_00])
        let draft = seed(c, status: "draft", total: 100_00, due: "2026-07-01", created: 500)
        try c.save()
        let vm = InvoiceListViewModel(context: c, sync: MockSyncEngine(),
                                      userId: "u1", profileId: "p1", today: today)
        let attnIds = vm.needsAttention.map { $0.invoice.id }
        #expect(attnIds == [overdue.id, dueSoon.id])     // overdue before due-soon
        let otherIds = Set(vm.others.map { $0.invoice.id })
        #expect(otherIds == [far.id, paid.id, draft.id])
        // The needs-attention partition carries the overdue/due-soon classification;
        // the badge stays the payment-state badge (both are unpaid here).
        #expect(vm.needsAttention[0].attention == .overdue)
        #expect(vm.needsAttention[1].attention == .dueSoon)
        #expect(vm.needsAttention[0].badge == .unpaid)
        #expect(vm.needsAttention[1].badge == .unpaid)
    }

    @Test("others are newest-first by createdAt")
    func othersOrder() throws {
        let c = try ctx()
        let older = seed(c, status: "draft", total: 50_00, due: nil, created: 100)
        let newer = seed(c, status: "draft", total: 50_00, due: nil, created: 900)
        try c.save()
        let vm = InvoiceListViewModel(context: c, sync: MockSyncEngine(),
                                      userId: "u1", profileId: "p1", today: "2026-07-10")
        #expect(vm.others.map { $0.invoice.id } == [newer.id, older.id])
    }

    @Test("needs-attention is scoped to the active profile")
    func scoping() throws {
        let c = try ctx()
        let mine = seed(c, status: "issued", total: 100_00, due: "2026-07-01", created: 100, profile: "p1")
        seed(c, status: "issued", total: 100_00, due: "2026-07-01", created: 200, profile: "p2") // other profile
        try c.save()
        let vm = InvoiceListViewModel(context: c, sync: MockSyncEngine(),
                                      userId: "u1", profileId: "p1", today: "2026-07-10")
        #expect(vm.needsAttention.map { $0.invoice.id } == [mine.id])
        #expect(vm.others.isEmpty)
    }

    @Test("delete soft-deletes + enqueues a delete + drops from the list")
    func delete() throws {
        let c = try ctx()
        let inv = seed(c, status: "draft", total: 50_00, due: nil, created: 100)
        try c.save()
        let sync = MockSyncEngine()
        let vm = InvoiceListViewModel(context: c, sync: sync, userId: "u1", profileId: "p1", today: "2026-07-10")
        vm.delete(inv)
        #expect(vm.others.isEmpty)
        #expect(sync.calls.contains { $0.entityType == .invoice && $0.op == "delete" })
        let live = try c.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.deletedAt == nil }))
        #expect(live.isEmpty)
    }

    @Test("overdueCount counts issued+unpaid past-due invoices for the profile")
    func overdueCount() throws {
        let c = try ctx()
        seed(c, status: "issued", total: 100_00, due: "2026-07-01", created: 1)   // overdue
        seed(c, status: "issued", total: 100_00, due: "2026-07-01", created: 2, payments: [100_00]) // paid
        seed(c, status: "issued", total: 100_00, due: "2026-09-01", created: 3)   // future
        seed(c, status: "issued", total: 100_00, due: "2026-07-01", created: 4, profile: "p2") // other profile
        try c.save()
        let n = InvoiceListViewModel.overdueCount(context: c, profileId: "p1", today: "2026-07-10")
        #expect(n == 1)
    }
}
