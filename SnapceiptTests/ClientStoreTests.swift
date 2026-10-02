import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("ClientStore")
struct ClientStoreTests {
    private func fixture() throws -> (ModelContext, MockSyncEngine, ClientStore) {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let sync = MockSyncEngine()
        return (context, sync, ClientStore(context: context, sync: sync, userId: "u1", profileId: "p1"))
    }

    @Test func clientCrudScopesBothUserAndProfile() throws {
        let (ctx, sync, store) = try fixture()
        let own = Client(userId: "u1", profileId: "p1", name: "Acme")
        let foreign = Client(userId: "u2", profileId: "p1", name: "Acme foreign")
        let other = Client(userId: "u1", profileId: "p2", name: "Acme other")
        for c in [own, foreign, other] { ctx.insert(c) }
        try ctx.save()
        #expect(try store.list(search: "ACME").map(\.id) == [own.id])
        for c in [foreign, other] {
            #expect(throws: (any Error).self) { try store.save(id: c.id, draft: ClientDraft(name: "Changed")) }
            #expect(throws: (any Error).self) { try store.delete(id: c.id) }
            #expect(c.name.hasPrefix("Acme"))
            #expect(c.deletedAt == nil)
        }
        #expect(sync.calls.isEmpty)
    }

    @Test func clientEditPreservesHistoricalSnapshots() throws {
        let (ctx, _, store) = try fixture()
        let client = try store.save(id: nil, draft: ClientDraft(name: "Original", email: "old@example.com"))
        let quote = Quote(userId: "u1", profileId: "p1", clientId: client.id, clientName: "Original", clientEmail: "old@example.com", status: "sent")
        quote.clientAddress = "Old address"; quote.clientMobile = "0400000000"
        let invoice = Invoice(userId: "u1", profileId: "p1", clientId: client.id, clientName: "Original", clientEmail: "old@example.com", status: "issued")
        ctx.insert(quote); ctx.insert(invoice); try ctx.save()
        let quoteUpdated = quote.updatedAt, invoiceUpdated = invoice.updatedAt
        _ = try store.save(id: client.id, draft: ClientDraft(name: "Renamed", email: "new@example.com", notes: "Private"))
        #expect(quote.clientName == "Original" && quote.clientEmail == "old@example.com")
        #expect(quote.clientAddress == "Old address" && quote.clientMobile == "0400000000")
        #expect(invoice.clientName == "Original" && invoice.clientEmail == "old@example.com")
        #expect(quote.updatedAt == quoteUpdated && invoice.updatedAt == invoiceUpdated)
    }

    @Test func clientDeleteCancelsFollowUpsKeepsDocuments() throws {
        let (ctx, sync, store) = try fixture()
        let client = try store.save(id: nil, draft: ClientDraft(name: "Acme"))
        let follow = ClientFollowUp(userId: "u1", profileId: "p1", clientId: client.id, title: "Call")
        let foreign = ClientFollowUp(userId: "u2", profileId: "p1", clientId: client.id, title: "Foreign")
        let other = ClientFollowUp(userId: "u1", profileId: "p2", clientId: client.id, title: "Other")
        let quote = Quote(userId: "u1", profileId: "p1", clientId: client.id, clientName: "Acme", status: "sent")
        let invoice = Invoice(userId: "u1", profileId: "p1", clientId: client.id, clientName: "Acme", status: "issued")
        let payment = Payment(userId: "u1", invoiceId: invoice.id, amountCents: 100, paidOn: "2026-10-01")
        for f in [follow, foreign, other] { ctx.insert(f) }
        ctx.insert(quote); ctx.insert(invoice); ctx.insert(payment); try ctx.save()
        let times = (quote.updatedAt, invoice.updatedAt, payment.updatedAt)
        sync.calls.removeAll()
        try store.delete(id: client.id)
        #expect(client.deletedAt != nil && follow.deletedAt == client.deletedAt)
        #expect(foreign.deletedAt == nil && other.deletedAt == nil)
        #expect(try store.list(search: "").isEmpty)
        #expect(quote.deletedAt == nil && invoice.deletedAt == nil && payment.deletedAt == nil)
        #expect(quote.clientId == client.id && invoice.clientId == client.id)
        #expect(quote.updatedAt == times.0 && invoice.updatedAt == times.1 && payment.updatedAt == times.2)
        #expect(sync.calls.count == 2)
        #expect(sync.calls.allSatisfy { $0.op == "delete" })
    }

    @Test func saveFailureDoesNotEnqueue() throws {
        let (ctx, sync, _) = try fixture()
        struct Failure: Error {}
        let store = ClientStore(context: ctx, sync: sync, userId: "u1", profileId: "p1", persist: { _ in throw Failure() })
        #expect(throws: Failure.self) { try store.save(id: nil, draft: ClientDraft(name: "Failed")) }
        #expect(sync.calls.isEmpty)
        #expect(try store.list(search: "").isEmpty)
        let client = Client(userId: "u1", profileId: "p1", name: "Original")
        let follow = ClientFollowUp(userId: "u1", profileId: "p1", clientId: client.id, title: "Call")
        ctx.insert(client); ctx.insert(follow); try ctx.save()
        #expect(throws: Failure.self) { try store.save(id: client.id, draft: ClientDraft(name: "Changed")) }
        #expect(client.name == "Original")
        #expect(throws: Failure.self) { try store.delete(id: client.id) }
        #expect(client.deletedAt == nil && follow.deletedAt == nil)
        #expect(sync.calls.isEmpty)
        // A later unrelated save must not accidentally persist the failed edits/deletion.
        ctx.insert(Client(userId: "u1", profileId: "p1", name: "Unrelated"))
        try ctx.save()
        let fresh = ModelContext(ctx.container)
        let cid = client.id, fid = follow.id
        let savedClient = try #require(fresh.fetch(FetchDescriptor<Client>(predicate: #Predicate { $0.id == cid })).first)
        let savedFollow = try #require(fresh.fetch(FetchDescriptor<ClientFollowUp>(predicate: #Predicate { $0.id == fid })).first)
        #expect(savedClient.name == "Original" && savedClient.deletedAt == nil && savedFollow.deletedAt == nil)
        #expect(try fresh.fetch(FetchDescriptor<Client>()).allSatisfy { $0.name != "Failed" })
    }

    @Test func validationAndNormalization() throws {
        let (_, sync, store) = try fixture()
        for draft in [ClientDraft(name: "\n "), ClientDraft(name: String(repeating: "a", count: 201)), ClientDraft(name: "Good", notes: String(repeating: "n", count: 10_001))] {
            #expect(throws: (any Error).self) { try store.save(id: nil, draft: draft) }
        }
        #expect(sync.calls.isEmpty)
        let c = try store.save(id: nil, draft: ClientDraft(name: "\n Good \n", email: " a@b.com ", mobilePhone: " 123 ", address: "\n Address \n", notes: " \n "))
        #expect(c.name == "Good" && c.email == "a@b.com" && c.mobilePhone == "123" && c.address == "Address" && c.notes == nil)
        _ = try store.save(id: c.id, draft: ClientDraft(name: String(repeating: "a", count: 200), notes: String(repeating: "n", count: 10_000)))
    }

    @Test func clientEditorShowsFailureWithoutSuccessDismissal() throws {
        let (ctx, sync, _) = try fixture()
        struct Failure: Error {}
        let store = ClientStore(context: ctx, sync: sync, userId: "u1", profileId: "p1", persist: { _ in throw Failure() })
        let editor = ClientEditViewModel(store: store)
        editor.draft = ClientDraft(name: "Acme", notes: "Private notes")
        var dismissed = false
        #expect(editor.save(onSaved: { _ in dismissed = true }) == false)
        #expect(editor.errorMessage != nil && dismissed == false && sync.calls.isEmpty)
        #expect(editor.draft.name == "Acme" && editor.draft.notes == "Private notes")
    }
}
