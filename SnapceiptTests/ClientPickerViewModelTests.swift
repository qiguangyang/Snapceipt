import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("ClientPickerViewModel")
struct ClientPickerViewModelTests {
    private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(container), MockSyncEngine())
    }

    private func vm(_ ctx: ModelContext, _ sync: MockSyncEngine) -> ClientPickerViewModel {
        ClientPickerViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
    }

    @Test("reload returns only the active profile's non-deleted clients, name-sorted")
    func reloadScoped() throws {
        let (ctx, sync) = try makeFixture()
        ctx.insert(Client(userId: "u1", profileId: "p1", name: "Beta"))
        ctx.insert(Client(userId: "u1", profileId: "p1", name: "Acme"))
        ctx.insert(Client(userId: "u2", profileId: "p1", name: "Foreign"))
        ctx.insert(Client(userId: "u1", profileId: "p2", name: "Other"))   // excluded
        try ctx.save()
        let v = vm(ctx, sync)
        #expect(v.clients.count == 2)
        #expect(v.clients[0].name == "Acme")   // name asc
        #expect(v.clients[1].name == "Beta")
    }

    @Test("create inserts a client scoped to the active profile and enqueues upsert")
    func createEnqueues() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        let c = v.create(name: "  New Co  ", email: " n@co.com ")
        #expect(c != nil)
        #expect(c?.name == "New Co")
        #expect(c?.email == "n@co.com")
        #expect(c?.profileId == "p1")
        #expect(v.clients.count == 1)
        #expect(sync.calls.count == 1)
        #expect(sync.calls[0].entityType == .client)
        #expect(sync.calls[0].op == "upsert")
    }

    @Test("create returns nil for a blank name (no insert, no enqueue)")
    func createBlankRejected() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        let c = v.create(name: "   ", email: nil)
        #expect(c == nil)
        #expect(v.clients.isEmpty)
        #expect(sync.calls.isEmpty)
    }

    @Test("create normalizes an empty email to nil")
    func createEmptyEmail() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        let c = v.create(name: "X", email: "   ")
        #expect(c?.email == nil)
    }

    @Test("create carries a trimmed multiline address; empty address normalizes to nil")
    func createCarriesAddress() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        let c = v.create(name: "Acme", email: nil, address: "  9 Client Rd\nMelbourne VIC 3000  ")
        #expect(c?.address == "9 Client Rd\nMelbourne VIC 3000")
        let blank = v.create(name: "Beta", email: nil, address: "   \n  ")
        #expect(blank?.address == nil)
    }

    @Test("filtered matches name + email, case-insensitive")
    func filtered() throws {
        let (ctx, sync) = try makeFixture()
        ctx.insert(Client(userId: "u1", profileId: "p1", name: "Acme Pty", email: "ap@acme.com"))
        ctx.insert(Client(userId: "u1", profileId: "p1", name: "Beta", email: "b@x.com"))
        try ctx.save()
        let v = vm(ctx, sync)
        #expect(v.filtered(search: "acme").count == 1)
        #expect(v.filtered(search: "B@X").count == 1)
        #expect(v.filtered(search: "  ").count == 2)   // blank -> all
    }

    @Test func failedCreateDoesNotSelectOrDismiss() throws {
        let (ctx, sync) = try makeFixture()
        struct Failure: Error {}
        let v = ClientPickerViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1", persist: { _ in throw Failure() })
        var selections = 0
        // The picker invokes onPick (which closes the sheet) only for a returned client.
        if v.create(name: "Failed", email: nil) != nil { selections += 1 }
        #expect(selections == 0 && v.errorMessage != nil && sync.calls.isEmpty)
        #expect(v.clients.isEmpty)
    }

    @Test func deleteUsesStoreAndCancelsFollowUps() throws {
        let (ctx, sync) = try makeFixture()
        let client = Client(userId: "u1", profileId: "p1", name: "Acme")
        let follow = ClientFollowUp(userId: "u1", profileId: "p1", clientId: client.id, title: "Call")
        ctx.insert(client); ctx.insert(follow); try ctx.save()
        let v = vm(ctx, sync)
        v.delete(client)
        #expect(v.clients.isEmpty && follow.deletedAt != nil)
        #expect(sync.calls.count == 2)
    }
}
