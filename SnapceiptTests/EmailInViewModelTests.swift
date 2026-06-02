import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("EmailInViewModel")
struct EmailInViewModelTests {
    private func fixture() throws -> (ModelContext, MockSyncEngine, MockAPIClient) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(container), MockSyncEngine(), MockAPIClient())
    }

    private func seedTxn(_ ctx: ModelContext, profileId: String, status: String, date: String, merchant: String) {
        ctx.insert(Transaction(userId: "u1", profileId: profileId, merchant: merchant, catKey: "office",
                               amountCents: -1000, txnDate: date, source: "email_in", extractionStatus: status))
    }

    @Test("inbox lists email_in txns for the active profile, failed first then newest")
    func failedFirst() throws {
        let (ctx, sync, api) = try fixture()
        seedTxn(ctx, profileId: "p1", status: "done", date: "2026-05-20", merchant: "Done-old")
        seedTxn(ctx, profileId: "p1", status: "failed", date: "2026-05-10", merchant: "Failed-old")
        seedTxn(ctx, profileId: "p1", status: "done", date: "2026-05-28", merchant: "Done-new")
        seedTxn(ctx, profileId: "p2", status: "failed", date: "2026-05-30", merchant: "Other-profile")
        try ctx.save()

        let vm = EmailInViewModel(context: ctx, sync: sync, api: api, userId: "u1", profileId: "p1")
        #expect(vm.inbox.map(\.merchant) == ["Failed-old", "Done-new", "Done-old"]) // p2 excluded
    }

    @Test("save applies edits, flips failed->done, signs the amount, and enqueues an upsert")
    func saveFlips() throws {
        let (ctx, sync, api) = try fixture()
        seedTxn(ctx, profileId: "p1", status: "failed", date: "2026-05-10", merchant: "")
        try ctx.save()
        let vm = EmailInViewModel(context: ctx, sync: sync, api: api, userId: "u1", profileId: "p1")
        let txn = vm.inbox[0]

        vm.save(txn, merchant: "Bunnings", amountCentsAbs: 4250, txnDate: "2026-05-11", catKey: "office")

        #expect(txn.merchant == "Bunnings")
        #expect(txn.amountCents == -4250)   // expense category -> negative
        #expect(txn.extractionStatus == "done")
        #expect(sync.calls.last?.op == "upsert")
        #expect(sync.calls.last?.entityType == .transaction)
    }

    @Test("save stores a positive amount for the income category")
    func saveIncomeSign() throws {
        let (ctx, sync, api) = try fixture()
        seedTxn(ctx, profileId: "p1", status: "done", date: "2026-05-10", merchant: "x")
        try ctx.save()
        let vm = EmailInViewModel(context: ctx, sync: sync, api: api, userId: "u1", profileId: "p1")
        vm.save(vm.inbox[0], merchant: "Client", amountCentsAbs: 9000, txnDate: "2026-05-10", catKey: "income")
        #expect(vm.inbox[0].amountCents == 9000)
    }

    @Test("loadAddress + rotate go through the API client")
    func addressFlow() async throws {
        let (ctx, sync, api) = try fixture()
        api.profileInboxHandler = { pid in InboxAddressResponse(profileId: pid, token: "t1", address: "r.t1@in.snapceipt.cc") }
        api.rotateProfileInboxHandler = { pid in InboxAddressResponse(profileId: pid, token: "t2", address: "r.t2@in.snapceipt.cc") }
        let vm = EmailInViewModel(context: ctx, sync: sync, api: api, userId: "u1", profileId: "p1")

        await vm.loadAddress()
        #expect(vm.address?.address == "r.t1@in.snapceipt.cc")
        await vm.rotate()
        #expect(vm.address?.address == "r.t2@in.snapceipt.cc")
        #expect(api.profileInboxCalls == ["p1"])
        #expect(api.rotateProfileInboxCalls == ["p1"])
    }

    @Test("loadAddress failure surfaces an errorMessage and leaves address nil")
    func loadAddressFailure() async throws {
        let (ctx, sync, api) = try fixture()
        api.profileInboxHandler = { _ in throw MockAPIClientError.unscripted }
        let vm = EmailInViewModel(context: ctx, sync: sync, api: api, userId: "u1", profileId: "p1")

        await vm.loadAddress()

        #expect(vm.address == nil)
        #expect(vm.errorMessage != nil)
        #expect(vm.isLoadingAddress == false)
        #expect(api.profileInboxCalls == ["p1"])
    }

    @Test("rotate failure surfaces an errorMessage")
    func rotateFailure() async throws {
        let (ctx, sync, api) = try fixture()
        api.rotateProfileInboxHandler = { _ in throw MockAPIClientError.unscripted }
        let vm = EmailInViewModel(context: ctx, sync: sync, api: api, userId: "u1", profileId: "p1")

        await vm.rotate()

        #expect(vm.errorMessage != nil)
        #expect(api.rotateProfileInboxCalls == ["p1"])
    }
}
