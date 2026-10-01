import Testing
import SwiftData
import Foundation
@testable import Snapceipt

@MainActor
@Suite("LegacyClientLinker")
struct LegacyClientLinkerTests {
    private func fixture() throws -> (ModelContext, MockSyncEngine, Client, ClientStore) {
        let ctx = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let sync = MockSyncEngine()
        let client = Client(userId: "u1", profileId: "p1", name: "Acme Person", email: "hello@example.com")
        ctx.insert(client); try ctx.save()
        return (ctx, sync, client, ClientStore(context: ctx, sync: sync, userId: "u1", profileId: "p1"))
    }

    @Test func suggestionsNeverWrite() throws {
        let (ctx, sync, client, _) = try fixture()
        let email = Quote(id: "q2", userId: "u1", profileId: "p1", clientEmail: " HELLO@example.com ")
        let name = Invoice(id: "i1", userId: "u1", profileId: "p1", clientName: "  ACME  \n Person ")
        let rejected = [Quote(userId: "u2", profileId: "p1", clientEmail: client.email), Quote(userId: "u1", profileId: "p2", clientName: client.name), Quote(userId: "u1", profileId: "p1", clientId: "other", clientName: client.name), Quote(userId: "u1", profileId: "p1", clientName: client.name, deletedAt: 1), Quote(userId: "u1", profileId: "p1", clientEmail: "hello+other@example.com")]
        for q in [email] + rejected { ctx.insert(q) }; ctx.insert(name); try ctx.save()
        let suggestions = LegacyClientLinker.suggestions(client: ClientSelection(client), userId: "u1", profileId: "p1", quotes: [email] + rejected, invoices: [name, Invoice(userId: "u2", profileId: "p1", clientEmail: client.email), Invoice(userId: "u1", profileId: "p2", clientName: client.name)])
        #expect(suggestions.map(\.documentId) == ["i1", "q2"])
        #expect(suggestions.map(\.reason) == [.name, .email])
        #expect(email.clientId == nil && name.clientId == nil && !ctx.hasChanges && sync.calls.isEmpty)
        #expect(LegacyClientLinker.suggestions(client: ClientSelection(id: "blank", name: " ", email: " "), userId: "u1", profileId: "p1", quotes: [Quote(userId: "u1", profileId: "p1", clientName: " ", clientEmail: "")], invoices: []).isEmpty)
    }

    @Test func ambiguousSameNameNeedsSelection() throws {
        let (ctx, sync, client, store) = try fixture()
        let a = Quote(userId: "u1", profileId: "p1", clientName: client.name)
        let b = Quote(userId: "u1", profileId: "p1", clientName: client.name)
        ctx.insert(a); ctx.insert(b); try ctx.save()
        let vm = LegacyDocumentLinkViewModel(store: store, client: ClientSelection(client))
        vm.load()
        #expect(vm.suggested.count == 2 && vm.selected.isEmpty && sync.calls.isEmpty)
        vm.toggle(.init(kind: .quote, id: a.id))
        var completed = false
        #expect(vm.confirm(onLinked: { completed = true }))
        #expect(completed && a.clientId == client.id && b.clientId == nil)
    }

    @Test func linkChangesOnlyIdAndEnvelope() throws {
        let (ctx, sync, client, store) = try fixture()
        let q = Quote(userId: "u1", profileId: "p1", number: "Q001", clientName: "Original", clientEmail: "old@example.com", clientAddress: "Old address", clientMobile: "0400", gstEnabled: true, gstInclusive: true, subtotalCents: 100, gstCents: 10, totalCents: 110, status: "invoiced", validUntil: "2026-10-31", sentAt: 20, pdfR2Key: "quote.pdf", invoiceId: "origin", gstRateBp: 1000, createdAt: 10, updatedAt: 11, rev: 7, lastEditedDeviceId: "device")
        let i = Invoice(userId: "u1", profileId: "p1", number: "I001", quoteId: q.id, clientName: "Original", clientEmail: "old@example.com", gstInclusive: true, subtotalCents: 100, gstCents: 10, totalCents: 110, status: "issued", issueDate: "2026-09-01", dueDate: "2026-10-01", issuedAt: 20, pdfR2Key: "invoice.pdf", gstRateBp: 1000, createdAt: 10, updatedAt: 11, rev: 8)
        let p = Payment(userId: "u1", invoiceId: i.id, amountCents: 70, paidOn: "2026-09-30")
        ctx.insert(q); ctx.insert(i); ctx.insert(p); try ctx.save()
        let registry = SyncEntityRegistry()
        let beforeQ = try historicalPayload(registry.encodePayload(entityType: .quote, entity: q))
        let beforeI = try historicalPayload(registry.encodePayload(entityType: .invoice, entity: i))
        let beforeP = try canonicalPayload(registry.encodePayload(entityType: .payment, entity: p))
        try store.linkExistingDocuments(clientId: client.id, documents: [.init(kind: .quote, id: q.id), .init(kind: .invoice, id: i.id)])
        #expect(q.clientId == client.id && i.clientId == client.id)
        #expect(try historicalPayload(registry.encodePayload(entityType: .quote, entity: q)) == beforeQ)
        #expect(try historicalPayload(registry.encodePayload(entityType: .invoice, entity: i)) == beforeI)
        #expect(try canonicalPayload(registry.encodePayload(entityType: .payment, entity: p)) == beforeP)
        #expect(sync.calls.count == 2)
    }

    @Test func confirmationRechecksCurrentScopeAndLink() throws {
        let (ctx, sync, client, store) = try fixture()
        let a = Quote(userId: "u1", profileId: "p1", clientName: client.name)
        let b = Invoice(userId: "u1", profileId: "p1", clientName: client.name)
        ctx.insert(a); ctx.insert(b); try ctx.save()
        b.clientId = "other"; try ctx.save()
        #expect(throws: (any Error).self) { try store.linkExistingDocuments(clientId: client.id, documents: [.init(kind: .quote, id: a.id), .init(kind: .invoice, id: b.id)]) }
        #expect(a.clientId == nil && b.clientId == "other" && sync.calls.isEmpty)
        b.clientId = nil; b.profileId = "p2"; try ctx.save()
        #expect(throws: (any Error).self) { try store.linkExistingDocuments(clientId: client.id, documents: [.init(kind: .quote, id: a.id), .init(kind: .invoice, id: b.id)]) }
        #expect(a.clientId == nil && sync.calls.isEmpty)
    }

    @Test func isolatedLinkPreservesPendingHistoricalAndUnrelatedEdits() throws {
        let (ctx, sync, client, store) = try fixture()
        let q = Quote(userId: "u1", profileId: "p1", clientName: "Saved original", totalCents: 100)
        let unrelated = Invoice(userId: "u1", profileId: "p1", clientName: "Saved unrelated", totalCents: 200)
        ctx.insert(q); ctx.insert(unrelated); try ctx.save()
        q.clientName = "Pending input"; q.totalCents = 999
        unrelated.totalCents = 888
        try store.linkExistingDocuments(clientId: client.id, documents: [.init(kind: .quote, id: q.id)])
        let fresh = ModelContext(ctx.container)
        let savedQ = try #require(fresh.fetch(FetchDescriptor<Quote>()).first)
        let savedI = try #require(fresh.fetch(FetchDescriptor<Invoice>()).first)
        #expect(savedQ.clientId == client.id && savedQ.clientName == "Saved original" && savedQ.totalCents == 100)
        #expect(savedI.totalCents == 200)
        #expect(q.clientName == "Pending input" && q.totalCents == 999 && unrelated.totalCents == 888 && ctx.hasChanges)
        #expect(sync.calls.count == 1)
    }

    @Test func manualPickerIsScopedAndFailureKeepsSelection() throws {
        let (ctx, sync, client, _) = try fixture()
        let q = Quote(userId: "u1", profileId: "p1", clientName: "Nonmatch")
        ctx.insert(q); ctx.insert(Quote(userId: "u2", profileId: "p1")); ctx.insert(Invoice(userId: "u1", profileId: "p2")); try ctx.save()
        struct Failure: Error {}
        var saves = 0
        let store = ClientStore(context: ctx, sync: sync, userId: "u1", profileId: "p1", persist: { _ in saves += 1; throw Failure() })
        let vm = LegacyDocumentLinkViewModel(store: store, client: ClientSelection(client))
        vm.load()
        #expect(vm.suggested.isEmpty && vm.manual.map(\.reference.id) == [q.id])
        vm.toggle(.init(kind: .quote, id: q.id))
        q.totalCents = 999
        var completed = false
        #expect(!vm.confirm(onLinked: { completed = true }))
        #expect(!completed && vm.errorMessage != nil && vm.selected.count == 1 && sync.calls.isEmpty && saves == 1)
        #expect(q.clientId == nil && q.totalCents == 999)
        let fresh = ModelContext(ctx.container)
        #expect(try fresh.fetch(FetchDescriptor<Quote>()).first?.clientId == nil)
    }

    @Test func realOutboxSavesOnlyCommittedAssociationPayload() throws {
        let (ctx, _, client, _) = try fixture()
        let q = Quote(userId: "u1", profileId: "p1", clientName: "Original", totalCents: 100)
        let invoice = Invoice(userId: "u1", profileId: "p1", clientName: "Invoice original", totalCents: 200)
        ctx.insert(q); ctx.insert(invoice); try ctx.save()
        let engine = SyncEngine(api: MockAPIClient(), context: ctx, auth: AuthStore(), toast: ToastCenter())
        var saves = 0
        let store = ClientStore(context: ctx, sync: engine, userId: "u1", profileId: "p1", persist: { saves += 1; try $0.save() })
        q.clientName = "Pending quote"; invoice.totalCents = 999; client.notes = "Pending notes"
        try store.linkExistingDocuments(clientId: client.id, documents: [.init(kind: .quote, id: q.id), .init(kind: .invoice, id: invoice.id), .init(kind: .quote, id: q.id)])
        let fresh = ModelContext(ctx.container)
        #expect(saves == 1)
        #expect(try fresh.fetch(FetchDescriptor<Quote>()).first?.clientName == "Original")
        #expect(try fresh.fetch(FetchDescriptor<Invoice>()).first?.totalCents == 200)
        #expect(try fresh.fetch(FetchDescriptor<Client>()).first?.notes == nil)
        let outbox = try fresh.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox.count == 2)
        for mutation in outbox {
            let payload = SyncEntityRegistry().decodePayload(mutation.payloadJSON)
            #expect(payload["clientId"]?.stringValue == client.id)
            if mutation.entityType == EntityType.quote.rawValue {
                #expect(payload["clientName"]?.stringValue == "Original")
            } else { #expect(payload["totalCents"]?.intValue == 200) }
        }
        #expect(q.clientName == "Pending quote" && invoice.totalCents == 999 && client.notes == "Pending notes" && ctx.hasChanges)
    }

    @Test func confirmationRejectsPendingLinkAndExternallyChangedRows() throws {
        let (ctx, sync, client, store) = try fixture()
        let q = Quote(userId: "u1", profileId: "p1")
        ctx.insert(q); try ctx.save()
        q.clientId = "pending-other"
        #expect(throws: (any Error).self) { try store.linkExistingDocuments(clientId: client.id, documents: [.init(kind: .quote, id: q.id)]) }
        #expect(q.clientId == "pending-other" && sync.calls.isEmpty)
        q.clientId = nil
        let external = ModelContext(ctx.container)
        let saved = try #require(external.fetch(FetchDescriptor<Quote>()).first)
        saved.clientId = "external-other"; try external.save()
        #expect(throws: (any Error).self) { try store.linkExistingDocuments(clientId: client.id, documents: [.init(kind: .quote, id: q.id)]) }
        #expect(sync.calls.isEmpty)
        saved.clientId = nil; saved.deletedAt = 1; try external.save()
        #expect(throws: (any Error).self) { try store.linkExistingDocuments(clientId: client.id, documents: [.init(kind: .quote, id: q.id)]) }
        #expect(throws: (any Error).self) { try store.linkExistingDocuments(clientId: client.id, documents: [.init(kind: .quote, id: "missing")]) }
        #expect(sync.calls.isEmpty)
    }

    @Test func targetMustRemainLiveInCurrentAccountAndProfile() throws {
        let (ctx, sync, client, store) = try fixture()
        let quote = Quote(userId: "u1", profileId: "p1")
        let foreign = Client(userId: "u2", profileId: "p1", name: "Foreign")
        let other = Client(userId: "u1", profileId: "p2", name: "Other")
        ctx.insert(quote); ctx.insert(foreign); ctx.insert(other); try ctx.save()
        for id in [foreign.id, other.id, "missing"] {
            #expect(throws: (any Error).self) { try store.linkExistingDocuments(clientId: id, documents: [.init(kind: .quote, id: quote.id)]) }
        }
        client.profileId = "p2"
        #expect(throws: (any Error).self) { try store.linkExistingDocuments(clientId: client.id, documents: [.init(kind: .quote, id: quote.id)]) }
        client.profileId = "p1"
        let reader = ModelContext(ctx.container)
        let id = client.id
        let savedClient = try #require(reader.fetch(FetchDescriptor<Client>(predicate: #Predicate { $0.id == id })).first)
        savedClient.deletedAt = 1; try reader.save()
        #expect(throws: (any Error).self) { try store.linkExistingDocuments(clientId: client.id, documents: [.init(kind: .quote, id: quote.id)]) }
        #expect(quote.clientId == nil && sync.calls.isEmpty)
    }

    @Test func pickerDisplaysPersistedOriginalSnapshotWithoutPreselection() throws {
        let (ctx, _, client, store) = try fixture()
        let q = Quote(userId: "u1", profileId: "p1", number: "Q123", clientName: client.name, clientEmail: client.email, totalCents: 1234, createdAt: 10)
        ctx.insert(q); try ctx.save()
        q.clientName = "Pending contact"; q.totalCents = 9999
        let vm = LegacyDocumentLinkViewModel(store: store, client: ClientSelection(client))
        vm.load()
        let candidate = try #require(vm.suggested.first)
        #expect(candidate.number == "Q123" && candidate.originalName == client.name && candidate.originalEmail == client.email)
        #expect(candidate.totalCents == 1234 && candidate.reason == .email && !candidate.date.isEmpty && vm.selected.isEmpty)
        #expect(q.clientName == "Pending contact" && q.totalCents == 9999 && ctx.hasChanges)
    }

    private func canonicalPayload(_ data: String) throws -> Data {
        let json = try JSONSerialization.jsonObject(with: Data(data.utf8))
        return try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
    }

    private func historicalPayload(_ data: String) throws -> Data {
        var json = try #require(JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any])
        json.removeValue(forKey: "clientId"); json.removeValue(forKey: "updatedAt")
        return try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
    }
}
