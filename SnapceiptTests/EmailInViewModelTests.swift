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

    @Test("loadAddress goes through the API client")
    func addressFlow() async throws {
        let (ctx, sync, api) = try fixture()
        api.profileInboxHandler = { pid in InboxAddressResponse(profileId: pid, token: "t1", address: "r.t1@in.snapceipt.cc") }
        let vm = EmailInViewModel(context: ctx, sync: sync, api: api, userId: "u1", profileId: "p1")

        await vm.loadAddress()
        #expect(vm.address?.address == "r.t1@in.snapceipt.cc")
        #expect(api.profileInboxCalls == ["p1"])
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

    @Test("loadAddress 403 sets proRequired (server says not Pro), not a generic errorMessage")
    func loadAddressForbidden() async throws {
        let (ctx, sync, api) = try fixture()
        api.profileInboxHandler = { _ in throw APIError(code: "FORBIDDEN", message: "Pro required", status: 403) }
        let vm = EmailInViewModel(context: ctx, sync: sync, api: api, userId: "u1", profileId: "p1")

        await vm.loadAddress()

        #expect(vm.proRequired == true)
        #expect(vm.errorMessage == nil)   // not the dead-button error path; the view shows upgrade
        #expect(vm.address == nil)
    }

    @Test("loadAddressIfPro no-ops for a free user (no network, no error)")
    func freeUserSkipsAddressLoad() async throws {
        let (ctx, sync, api) = try fixture()
        // No profileInboxHandler set: if loadAddressIfPro hit the API it would throw
        // MockAPIClientError.unscripted (now a 403 server-side) and set errorMessage.
        let vm = EmailInViewModel(context: ctx, sync: sync, api: api, userId: "u1", profileId: "p1")

        await vm.loadAddressIfPro(isPro: false)

        #expect(vm.address == nil)
        #expect(vm.errorMessage == nil)        // no doomed 403 surfaced
        #expect(api.profileInboxCalls.isEmpty) // API never touched
    }

    @Test("loadAddressIfPro loads through the API for a Pro user")
    func proUserLoadsAddress() async throws {
        let (ctx, sync, api) = try fixture()
        api.profileInboxHandler = { pid in
            InboxAddressResponse(profileId: pid, token: "t1", address: "r.t1@in.snapceipt.cc")
        }
        let vm = EmailInViewModel(context: ctx, sync: sync, api: api, userId: "u1", profileId: "p1")

        await vm.loadAddressIfPro(isPro: true)

        #expect(vm.address?.address == "r.t1@in.snapceipt.cc")
        #expect(api.profileInboxCalls == ["p1"])
    }
}
