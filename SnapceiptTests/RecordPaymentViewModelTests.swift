import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("RecordPaymentViewModel")
struct RecordPaymentViewModelTests {
    private func fixture(total: Int, paid: [Int]) throws -> (ModelContext, MockSyncEngine, String) {
        let ctx = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let inv = Invoice(userId: "u1", profileId: "p1", totalCents: total, status: "issued")
        ctx.insert(inv)
        for amt in paid { ctx.insert(Payment(userId: "u1", invoiceId: inv.id, amountCents: amt, paidOn: "2026-06-18")) }
        try ctx.save()
        return (ctx, MockSyncEngine(), inv.id)
    }

    @Test("amount defaults to the outstanding balance")
    func defaultsOutstanding() throws {
        let (ctx, sync, id) = try fixture(total: 100_00, paid: [40_00])
        let vm = RecordPaymentViewModel(context: ctx, sync: sync, userId: "u1", invoiceId: id)
        #expect(vm.outstandingCents == 60_00)
        #expect(vm.amountCents == 60_00)
        #expect(vm.canSave == true)
    }

    @Test("save inserts a Payment, enqueues an upsert")
    func saves() throws {
        let (ctx, sync, id) = try fixture(total: 100_00, paid: [])
        let vm = RecordPaymentViewModel(context: ctx, sync: sync, userId: "u1", invoiceId: id)
        vm.amountCents = 30_00
        vm.method = "bank"
        let ok = vm.save()
        #expect(ok == true)
        let pays = try ctx.fetch(FetchDescriptor<Payment>(predicate: #Predicate { $0.invoiceId == id && $0.deletedAt == nil }))
        #expect(pays.count == 1)
        #expect(pays[0].amountCents == 30_00)
        #expect(pays[0].method == "bank")
        #expect(sync.calls.contains { $0.entityType == .payment && $0.op == "upsert" })
    }

    @Test("a zero amount cannot be saved")
    func zeroBlocked() throws {
        let (ctx, sync, id) = try fixture(total: 100_00, paid: [100_00])
        let vm = RecordPaymentViewModel(context: ctx, sync: sync, userId: "u1", invoiceId: id)
        #expect(vm.outstandingCents == 0)
        vm.amountCents = 0
        #expect(vm.canSave == false)
        #expect(vm.save() == false)
        let pays = try ctx.fetch(FetchDescriptor<Payment>(predicate: #Predicate { $0.invoiceId == id }))
        #expect(pays.count == 1)   // only the seeded one
    }
}
